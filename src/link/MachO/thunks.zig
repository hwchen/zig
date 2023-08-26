//! An algorithm for allocating output machine code section (aka `__TEXT,__text`),
//! and insertion of range extending thunks. As such, this algorithm is only run
//! for a target that requires range extenders such as arm64.
//!
//! The algorithm works pessimistically and assumes that any reference to an Atom in
//! another output section is out of range.

const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.thunks);
const macho = std.macho;
const math = std.math;
const mem = std.mem;

const aarch64 = @import("../../arch/aarch64/bits.zig");

const Allocator = mem.Allocator;
const Atom = @import("Atom.zig");
const MachO = @import("../MachO.zig");
const Relocation = @import("Relocation.zig");
const SymbolWithLoc = MachO.SymbolWithLoc;
const Zld = @import("zld.zig").Zld;

/// Branch instruction has 26 bits immediate but 4 byte aligned.
const jump_bits = @bitSizeOf(i28);

const max_distance = (1 << (jump_bits - 1));

/// A branch will need an extender if its target is larger than
/// `2^(jump_bits - 1) - margin` where margin is some arbitrary number.
/// mold uses 5MiB margin, while ld64 uses 4MiB margin. We will follow mold
/// and assume margin to be 5MiB.
const max_allowed_distance = max_distance - 0x500_000;

pub const Thunk = struct {
    start_index: Atom.Index,
    len: u32,

    targets: std.MultiArrayList(Target) = .{},
    lookup: std.AutoHashMapUnmanaged(Target, u32) = .{},

    pub const Tag = enum {
        stub,
        atom,
    };

    pub const Target = struct {
        tag: Tag,
        target: SymbolWithLoc,
    };

    pub const Index = u32;

    pub fn deinit(self: *Thunk, gpa: Allocator) void {
        self.targets.deinit(gpa);
        self.lookup.deinit(gpa);
    }

    pub fn getStartAtomIndex(self: Thunk) Atom.Index {
        assert(self.len != 0);
        return self.start_index;
    }

    pub fn getEndAtomIndex(self: Thunk) Atom.Index {
        assert(self.len != 0);
        return self.start_index + self.len - 1;
    }

    pub fn getSize(self: Thunk) u64 {
        return 12 * self.len;
    }

    pub fn getAlignment() u32 {
        return @alignOf(u32);
    }

    pub fn getTrampoline(self: Thunk, zld: *Zld, tag: Tag, target: SymbolWithLoc) ?SymbolWithLoc {
        const atom_index = self.lookup.get(.{ .tag = tag, .target = target }) orelse return null;
        return zld.getAtom(atom_index).getSymbolWithLoc();
    }
};

pub fn createThunks(zld: *Zld, sect_id: u8) !void {
    const header = &zld.sections.items(.header)[sect_id];
    if (header.size == 0) return;

    const gpa = zld.gpa;
    const first_atom_index = zld.sections.items(.first_atom_index)[sect_id].?;

    header.size = 0;
    header.@"align" = 0;

    var atom_count: u32 = 0;

    {
        var atom_index = first_atom_index;
        while (true) {
            const atom = zld.getAtom(atom_index);
            const sym = zld.getSymbolPtr(atom.getSymbolWithLoc());
            sym.n_value = 0;
            atom_count += 1;

            if (atom.next_index) |next_index| {
                atom_index = next_index;
            } else break;
        }
    }

    var allocated = std.AutoHashMap(Atom.Index, void).init(gpa);
    defer allocated.deinit();
    try allocated.ensureTotalCapacity(atom_count);

    var group_start = first_atom_index;
    var group_end = first_atom_index;
    var offset: u64 = 0;

    while (true) {
        const group_start_atom = zld.getAtom(group_start);
        log.debug("GROUP START at {d}", .{group_start});

        while (true) {
            const atom = zld.getAtom(group_end);
            offset = mem.alignForward(u64, offset, try math.powi(u32, 2, atom.alignment));

            const sym = zld.getSymbolPtr(atom.getSymbolWithLoc());
            sym.n_value = offset;
            offset += atom.size;

            zld.logAtom(group_end, log);

            header.@"align" = @max(header.@"align", atom.alignment);

            allocated.putAssumeCapacityNoClobber(group_end, {});

            const group_start_sym = zld.getSymbol(group_start_atom.getSymbolWithLoc());
            if (offset - group_start_sym.n_value >= max_allowed_distance) break;

            if (atom.next_index) |next_index| {
                group_end = next_index;
            } else break;
        }
        log.debug("GROUP END at {d}", .{group_end});

        // Insert thunk at group_end
        const thunk_index = @as(u32, @intCast(zld.thunks.items.len));
        try zld.thunks.append(gpa, .{ .start_index = undefined, .len = 0 });

        // Scan relocs in the group and create trampolines for any unreachable callsite.
        var atom_index = group_start;
        while (true) {
            const atom = zld.getAtom(atom_index);
            try scanRelocs(
                zld,
                atom_index,
                allocated,
                thunk_index,
                group_end,
            );

            if (atom_index == group_end) break;

            if (atom.next_index) |next_index| {
                atom_index = next_index;
            } else break;
        }

        offset = mem.alignForward(u64, offset, Thunk.getAlignment());
        allocateThunk(zld, thunk_index, offset, header);
        offset += zld.thunks.items[thunk_index].getSize();

        const thunk = zld.thunks.items[thunk_index];
        if (thunk.len == 0) {
            const group_end_atom = zld.getAtom(group_end);
            if (group_end_atom.next_index) |next_index| {
                group_start = next_index;
                group_end = next_index;
            } else break;
        } else {
            const thunk_end_atom_index = thunk.getEndAtomIndex();
            const thunk_end_atom = zld.getAtom(thunk_end_atom_index);
            if (thunk_end_atom.next_index) |next_index| {
                group_start = next_index;
                group_end = next_index;
            } else break;
        }
    }

    header.size = @as(u32, @intCast(offset));
}

fn allocateThunk(
    zld: *Zld,
    thunk_index: Thunk.Index,
    base_offset: u64,
    header: *macho.section_64,
) void {
    const thunk = zld.thunks.items[thunk_index];
    if (thunk.len == 0) return;

    const first_atom_index = thunk.getStartAtomIndex();
    const end_atom_index = thunk.getEndAtomIndex();

    var atom_index = first_atom_index;
    var offset = base_offset;
    while (true) {
        const atom = zld.getAtom(atom_index);
        offset = mem.alignForward(u64, offset, Thunk.getAlignment());

        const sym = zld.getSymbolPtr(atom.getSymbolWithLoc());
        sym.n_value = offset;
        offset += atom.size;

        zld.logAtom(atom_index, log);

        header.@"align" = @max(header.@"align", atom.alignment);

        if (end_atom_index == atom_index) break;

        if (atom.next_index) |next_index| {
            atom_index = next_index;
        } else break;
    }
}

fn scanRelocs(
    zld: *Zld,
    atom_index: Atom.Index,
    allocated: std.AutoHashMap(Atom.Index, void),
    thunk_index: Thunk.Index,
    group_end: Atom.Index,
) !void {
    const atom = zld.getAtom(atom_index);
    const object = zld.objects.items[atom.getFile().?];

    const base_offset = if (object.getSourceSymbol(atom.sym_index)) |source_sym| blk: {
        const source_sect = object.getSourceSection(source_sym.n_sect - 1);
        break :blk @as(i32, @intCast(source_sym.n_value - source_sect.addr));
    } else 0;

    const code = Atom.getAtomCode(zld, atom_index);
    const relocs = Atom.getAtomRelocs(zld, atom_index);
    const ctx = Atom.getRelocContext(zld, atom_index);

    for (relocs) |rel| {
        if (!relocNeedsThunk(rel)) continue;

        const target = Atom.parseRelocTarget(zld, .{
            .object_id = atom.getFile().?,
            .rel = rel,
            .code = code,
            .base_offset = ctx.base_offset,
            .base_addr = ctx.base_addr,
        });
        if (isReachable(zld, atom_index, rel, base_offset, target, allocated)) continue;

        log.debug("{x}: source = {s}@{x}, target = {s}@{x} unreachable", .{
            rel.r_address - base_offset,
            zld.getSymbolName(atom.getSymbolWithLoc()),
            zld.getSymbol(atom.getSymbolWithLoc()).n_value,
            zld.getSymbolName(target),
            zld.getSymbol(target).n_value,
        });

        const gpa = zld.gpa;
        const target_sym = zld.getSymbol(target);
        const thunk = &zld.thunks.items[thunk_index];

        const tag: Thunk.Tag = if (target_sym.undf()) .stub else .atom;
        const thunk_target: Thunk.Target = .{ .tag = tag, .target = target };
        const gop = try thunk.lookup.getOrPut(gpa, thunk_target);
        if (!gop.found_existing) {
            gop.value_ptr.* = try pushThunkAtom(zld, thunk, group_end);
            try thunk.targets.append(gpa, thunk_target);
        }

        try zld.thunk_table.put(gpa, atom_index, thunk_index);
    }
}

fn pushThunkAtom(zld: *Zld, thunk: *Thunk, group_end: Atom.Index) !Atom.Index {
    const thunk_atom_index = try createThunkAtom(zld);

    const thunk_atom = zld.getAtomPtr(thunk_atom_index);
    const end_atom_index = if (thunk.len == 0) group_end else thunk.getEndAtomIndex();
    const end_atom = zld.getAtomPtr(end_atom_index);

    if (end_atom.next_index) |first_after_index| {
        const first_after_atom = zld.getAtomPtr(first_after_index);
        first_after_atom.prev_index = thunk_atom_index;
        thunk_atom.next_index = first_after_index;
    }

    end_atom.next_index = thunk_atom_index;
    thunk_atom.prev_index = end_atom_index;

    if (thunk.len == 0) {
        thunk.start_index = thunk_atom_index;
    }

    thunk.len += 1;

    return thunk_atom_index;
}

inline fn relocNeedsThunk(rel: macho.relocation_info) bool {
    const rel_type = @as(macho.reloc_type_arm64, @enumFromInt(rel.r_type));
    return rel_type == .ARM64_RELOC_BRANCH26;
}

fn isReachable(
    zld: *Zld,
    atom_index: Atom.Index,
    rel: macho.relocation_info,
    base_offset: i32,
    target: SymbolWithLoc,
    allocated: std.AutoHashMap(Atom.Index, void),
) bool {
    if (zld.stubs_table.lookup.contains(target)) return false;

    const source_atom = zld.getAtom(atom_index);
    const source_sym = zld.getSymbol(source_atom.getSymbolWithLoc());

    const target_object = zld.objects.items[target.getFile().?];
    const target_atom_index = target_object.getAtomIndexForSymbol(target.sym_index).?;
    const target_atom = zld.getAtom(target_atom_index);
    const target_sym = zld.getSymbol(target_atom.getSymbolWithLoc());

    if (source_sym.n_sect != target_sym.n_sect) return false;

    if (!allocated.contains(target_atom_index)) return false;

    const source_addr = source_sym.n_value + @as(u32, @intCast(rel.r_address - base_offset));
    const target_addr = if (Atom.relocRequiresGot(zld, rel))
        zld.getGotEntryAddress(target).?
    else
        Atom.getRelocTargetAddress(zld, target, false) catch unreachable;
    _ = Relocation.calcPcRelativeDisplacementArm64(source_addr, target_addr) catch
        return false;

    return true;
}

fn createThunkAtom(zld: *Zld) !Atom.Index {
    const sym_index = try zld.allocateSymbol();
    const atom_index = try zld.createAtom(sym_index, .{ .size = @sizeOf(u32) * 3, .alignment = 2 });
    const sym = zld.getSymbolPtr(.{ .sym_index = sym_index });
    sym.n_type = macho.N_SECT;
    sym.n_sect = zld.text_section_index.? + 1;
    return atom_index;
}

pub fn writeThunkCode(zld: *Zld, thunk: *const Thunk, writer: anytype) !void {
    const slice = thunk.targets.slice();
    for (thunk.getStartAtomIndex()..thunk.getEndAtomIndex(), 0..) |atom_index, target_index| {
        const atom = zld.getAtom(@intCast(atom_index));
        const sym = zld.getSymbol(atom.getSymbolWithLoc());
        const source_addr = sym.n_value;
        const tag = slice.items(.tag)[target_index];
        const target = slice.items(.target)[target_index];
        const target_addr = switch (tag) {
            .stub => zld.getStubsEntryAddress(target).?,
            .atom => zld.getSymbol(target).n_value,
        };
        const pages = Relocation.calcNumberOfPages(source_addr, target_addr);
        try writer.writeIntLittle(u32, aarch64.Instruction.adrp(.x16, pages).toU32());
        const off = try Relocation.calcPageOffset(target_addr, .arithmetic);
        try writer.writeIntLittle(u32, aarch64.Instruction.add(.x16, .x16, off, false).toU32());
        try writer.writeIntLittle(u32, aarch64.Instruction.br(.x16).toU32());
    }
}
