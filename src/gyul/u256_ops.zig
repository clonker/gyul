const std = @import("std");

const max_u256: u256 = std.math.maxInt(u256);
const min_i256: i256 = std.math.minInt(i256);

// ── Arithmetic (wrapping mod 2^256) ──────────────────────────────────

pub fn add(x: u256, y: u256) u256 {
    return x +% y;
}

pub fn sub(x: u256, y: u256) u256 {
    return x -% y;
}

pub fn mul(x: u256, y: u256) u256 {
    return x *% y;
}

pub fn div(x: u256, y: u256) u256 {
    if (y == 0) return 0;
    return x / y;
}

pub fn sdiv(x: u256, y: u256) u256 {
    if (y == 0) return 0;
    const sx: i256 = @bitCast(x);
    const sy: i256 = @bitCast(y);
    // Guard: minInt(i256) / -1 overflows in two's complement.
    // EVM returns minInt(i256) (i.e. the bit pattern for -2^255).
    if (sx == min_i256 and sy == -1) return x;
    return @bitCast(@divTrunc(sx, sy));
}

pub fn mod_(x: u256, y: u256) u256 {
    if (y == 0) return 0;
    return x % y;
}

pub fn smod(x: u256, y: u256) u256 {
    if (y == 0) return 0;
    const sx: i256 = @bitCast(x);
    const sy: i256 = @bitCast(y);
    return @bitCast(@rem(sx, sy));
}

pub fn exp(base: u256, exponent: u256) u256 {
    if (exponent == 0) return 1;
    var result: u256 = 1;
    var b = base;
    var e = exponent;
    while (e > 0) {
        if (e & 1 == 1) {
            result = result *% b;
        }
        b = b *% b;
        e >>= 1;
    }
    return result;
}

pub fn addmod(x: u256, y: u256, m: u256) u256 {
    if (m == 0) return 0;
    const xw: u512 = x;
    const yw: u512 = y;
    const mw: u512 = m;
    return @truncate((xw + yw) % mw);
}

pub fn mulmod(x: u256, y: u256, m: u256) u256 {
    if (m == 0) return 0;
    const xw: u512 = x;
    const yw: u512 = y;
    const mw: u512 = m;
    return @truncate((xw * yw) % mw);
}

pub fn signextend(b: u256, x: u256) u256 {
    if (b >= 31) return x;
    // b fits in a u8 since b < 31
    const bit_pos: u8 = @intCast(b * 8 + 7);
    const mask: u256 = (@as(u256, 1) << bit_pos) -% 1;
    const sign_bit = (x >> bit_pos) & 1;
    if (sign_bit != 0) {
        return x | ~mask;
    } else {
        return x & mask;
    }
}

// ── Bitwise ──────────────────────────────────────────────────────────

pub fn and_(x: u256, y: u256) u256 {
    return x & y;
}

pub fn or_(x: u256, y: u256) u256 {
    return x | y;
}

pub fn xor(x: u256, y: u256) u256 {
    return x ^ y;
}

pub fn not(x: u256) u256 {
    return ~x;
}

pub fn byte_(n: u256, x: u256) u256 {
    if (n >= 32) return 0;
    // Big-endian: byte 0 is the most significant byte
    const shift: u8 = @intCast((31 - @as(u8, @intCast(n))) * 8);
    return (x >> shift) & 0xFF;
}

pub fn shl(shift: u256, value: u256) u256 {
    if (shift >= 256) return 0;
    return value << @intCast(shift);
}

pub fn shr(shift: u256, value: u256) u256 {
    if (shift >= 256) return 0;
    return value >> @intCast(shift);
}

pub fn sar(shift: u256, value: u256) u256 {
    const sv: i256 = @bitCast(value);
    if (shift >= 256) {
        // All bits shifted out: result is 0 if positive, -1 (MAX_U256) if negative
        return if (sv < 0) max_u256 else 0;
    }
    return @bitCast(sv >> @intCast(shift));
}

// ── Comparison (return 0 or 1) ───────────────────────────────────────

pub fn lt(x: u256, y: u256) u256 {
    return if (x < y) 1 else 0;
}

pub fn gt(x: u256, y: u256) u256 {
    return if (x > y) 1 else 0;
}

pub fn slt(x: u256, y: u256) u256 {
    const sx: i256 = @bitCast(x);
    const sy: i256 = @bitCast(y);
    return if (sx < sy) 1 else 0;
}

pub fn sgt(x: u256, y: u256) u256 {
    const sx: i256 = @bitCast(x);
    const sy: i256 = @bitCast(y);
    return if (sx > sy) 1 else 0;
}

pub fn eq(x: u256, y: u256) u256 {
    return if (x == y) 1 else 0;
}

pub fn iszero(x: u256) u256 {
    return if (x == 0) 1 else 0;
}

pub fn clz_(x: u256) u256 {
    return @clz(x);
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "add: basic" {
    try testing.expectEqual(@as(u256, 3), add(1, 2));
    try testing.expectEqual(@as(u256, 0), add(max_u256, 1)); // wraps
    try testing.expectEqual(max_u256, add(max_u256, 0));
}

test "sub: basic" {
    try testing.expectEqual(@as(u256, 1), sub(3, 2));
    try testing.expectEqual(max_u256, sub(0, 1)); // wraps
    try testing.expectEqual(@as(u256, 0), sub(0, 0));
}

test "mul: basic" {
    try testing.expectEqual(@as(u256, 6), mul(2, 3));
    try testing.expectEqual(max_u256 -% 1, mul(max_u256, 2)); // MAX * 2 = -1 * 2 = -2
    try testing.expectEqual(@as(u256, 0), mul(0, max_u256));
}

test "div: basic and division by zero" {
    try testing.expectEqual(@as(u256, 5), div(10, 2));
    try testing.expectEqual(@as(u256, 0), div(1, 0)); // div by zero = 0
    try testing.expectEqual(@as(u256, 0), div(0, 5));
    try testing.expectEqual(@as(u256, 1), div(max_u256, max_u256));
}

test "sdiv: signed division" {
    // -1 / -1 = 1
    try testing.expectEqual(@as(u256, 1), sdiv(max_u256, max_u256));
    // sdiv by zero = 0
    try testing.expectEqual(@as(u256, 0), sdiv(1, 0));
    // MIN_I256 / -1 = MIN_I256 (overflow case)
    const min_i256_as_u256: u256 = @bitCast(min_i256);
    try testing.expectEqual(min_i256_as_u256, sdiv(min_i256_as_u256, max_u256));
    // 10 / 2 = 5
    try testing.expectEqual(@as(u256, 5), sdiv(10, 2));
    // -6 / 2 = -3
    const neg6: u256 = @bitCast(@as(i256, -6));
    const neg3: u256 = @bitCast(@as(i256, -3));
    try testing.expectEqual(neg3, sdiv(neg6, 2));
}

test "mod: basic and mod by zero" {
    try testing.expectEqual(@as(u256, 1), mod_(10, 3));
    try testing.expectEqual(@as(u256, 0), mod_(1, 0)); // mod by zero = 0
    try testing.expectEqual(@as(u256, 0), mod_(9, 3));
    try testing.expectEqual(@as(u256, 3), mod_(0x0F, 4));
}

test "smod: signed modulo" {
    // smod by zero = 0
    try testing.expectEqual(@as(u256, 0), smod(1, 0));
    // 10 smod 3 = 1
    try testing.expectEqual(@as(u256, 1), smod(10, 3));
    // -8 smod 3 = -2 (sign follows dividend)
    const neg8: u256 = @bitCast(@as(i256, -8));
    const neg2: u256 = @bitCast(@as(i256, -2));
    try testing.expectEqual(neg2, smod(neg8, 3));
}

test "exp: modular exponentiation" {
    try testing.expectEqual(@as(u256, 1), exp(0, 0)); // 0^0 = 1
    try testing.expectEqual(@as(u256, 1), exp(2, 0)); // x^0 = 1
    try testing.expectEqual(@as(u256, 8), exp(2, 3)); // 2^3 = 8
    try testing.expectEqual(@as(u256, 0), exp(2, 256)); // 2^256 wraps to 0
    // 2^255 = 0x80...00
    const expected_2_255: u256 = @as(u256, 1) << 255;
    try testing.expectEqual(expected_2_255, exp(2, 255));
    try testing.expectEqual(@as(u256, 0), exp(0, 1)); // 0^n = 0
}

test "addmod: with overflow protection" {
    try testing.expectEqual(@as(u256, 0), addmod(1, 2, 0)); // mod 0 = 0
    try testing.expectEqual(@as(u256, 1), addmod(10, 10, 19)); // 20 % 19 = 1
    // MAX + 1 mod 2 = 0 (overflow in u256 but not in u512)
    try testing.expectEqual(@as(u256, 0), addmod(max_u256, 1, 2));
    try testing.expectEqual(@as(u256, 2), addmod(7, 10, 3)); // 17 % 3 = 2
}

test "mulmod: with overflow protection" {
    try testing.expectEqual(@as(u256, 0), mulmod(1, 2, 0)); // mod 0 = 0
    try testing.expectEqual(@as(u256, 1), mulmod(10, 10, 9)); // 100 % 9 = 1
    // MAX * MAX mod MAX = 0
    try testing.expectEqual(@as(u256, 0), mulmod(max_u256, max_u256, max_u256));
}

test "signextend: sign extension" {
    // signextend(0, 0xFF) -> extend sign from bit 7: 0xFF..FF
    try testing.expectEqual(max_u256, signextend(0, 0xFF));
    // signextend(0, 0x7F) -> positive, stays 0x7F
    try testing.expectEqual(@as(u256, 0x7F), signextend(0, 0x7F));
    // signextend(31, x) -> no change (all 256 bits covered)
    try testing.expectEqual(@as(u256, 42), signextend(31, 42));
    try testing.expectEqual(max_u256, signextend(31, max_u256));
    // signextend(1, 0x80FF) -> extend from bit 15: 0xFF..80FF
    try testing.expectEqual(max_u256 -% 0x7F00, signextend(1, 0x80FF));
    // Large b (>= 31) returns x unchanged
    try testing.expectEqual(@as(u256, 123), signextend(100, 123));
}

test "bitwise: and, or, xor, not" {
    try testing.expectEqual(@as(u256, 0), and_(0xFF, 0xFF00));
    try testing.expectEqual(@as(u256, 0xFFFF), or_(0xFF, 0xFF00));
    try testing.expectEqual(@as(u256, 0xFFFF), xor(0xFF, 0xFF00));
    try testing.expectEqual(max_u256, not(0));
    try testing.expectEqual(@as(u256, 0), not(max_u256));
}

test "byte: big-endian extraction" {
    // byte 0 is the most significant byte
    const val: u256 = @as(u256, 0xAB) << 248;
    try testing.expectEqual(@as(u256, 0xAB), byte_(0, val));
    // byte 31 is the least significant byte
    try testing.expectEqual(@as(u256, 0xFF), byte_(31, 0xFF));
    // byte 32+ returns 0
    try testing.expectEqual(@as(u256, 0), byte_(32, max_u256));
    try testing.expectEqual(@as(u256, 0), byte_(max_u256, max_u256));
}

test "shl: shift left" {
    try testing.expectEqual(@as(u256, 2), shl(1, 1));
    try testing.expectEqual(@as(u256, 0), shl(256, 1)); // shift >= 256 = 0
    try testing.expectEqual(@as(u256, 0), shl(0, 0));
    try testing.expectEqual(@as(u256, 1) << 255, shl(255, 1));
}

test "shr: logical shift right" {
    try testing.expectEqual(@as(u256, 1), shr(1, 2));
    try testing.expectEqual(@as(u256, 0), shr(256, max_u256)); // shift >= 256 = 0
    try testing.expectEqual(@as(u256, 0), shr(1, 1)); // 1 >> 1 = 0
}

test "sar: arithmetic shift right" {
    // Positive value: sar behaves like shr
    try testing.expectEqual(@as(u256, 1), sar(1, 2));
    // Negative value (sign bit set): fills with 1s
    try testing.expectEqual(max_u256, sar(1, max_u256)); // -1 >> 1 = -1
    // shift >= 256 with negative value = MAX (all 1s)
    try testing.expectEqual(max_u256, sar(256, max_u256));
    // shift >= 256 with positive value = 0
    try testing.expectEqual(@as(u256, 0), sar(256, 1));
    // MSB set, shift by 1: 0x80..00 >> 1 = 0xC0..00
    const msb: u256 = @as(u256, 1) << 255;
    const expected: u256 = @as(u256, 3) << 254;
    try testing.expectEqual(expected, sar(1, msb));
}

test "comparison: lt, gt, eq, iszero" {
    try testing.expectEqual(@as(u256, 1), lt(1, 2));
    try testing.expectEqual(@as(u256, 0), lt(2, 1));
    try testing.expectEqual(@as(u256, 0), lt(1, 1));
    try testing.expectEqual(@as(u256, 1), gt(2, 1));
    try testing.expectEqual(@as(u256, 0), gt(1, 2));
    try testing.expectEqual(@as(u256, 1), eq(0, 0));
    try testing.expectEqual(@as(u256, 1), eq(42, 42));
    try testing.expectEqual(@as(u256, 0), eq(1, 2));
    try testing.expectEqual(@as(u256, 1), iszero(0));
    try testing.expectEqual(@as(u256, 0), iszero(1));
    try testing.expectEqual(@as(u256, 0), iszero(max_u256));
}

test "comparison: slt, sgt (signed)" {
    // -1 (MAX_U256) < 0 in signed
    try testing.expectEqual(@as(u256, 1), slt(max_u256, 0));
    try testing.expectEqual(@as(u256, 0), slt(0, max_u256));
    // 0 > -1 in signed
    try testing.expectEqual(@as(u256, 1), sgt(0, max_u256));
    try testing.expectEqual(@as(u256, 0), sgt(max_u256, 0));
    // equal
    try testing.expectEqual(@as(u256, 0), slt(max_u256, max_u256));
    try testing.expectEqual(@as(u256, 0), sgt(max_u256, max_u256));
}
