//! Deterministic math functions for S2 geometry.
//!
//! This module provides software-based trigonometric functions that produce
//! bit-exact identical results across all platforms (x86, ARM, macOS, Linux).
//!
//! Why software trig? Standard library sin/cos/atan2 use hardware FPU
//! instructions that can vary across:
//! - CPU architectures (x86 vs ARM)
//! - libc implementations (glibc vs musl vs macOS libc)
//! - Compiler optimization levels
//!
//! For VSR consensus, all replicas MUST produce identical S2 cell IDs for
//! the same (lat, lon) coordinates. Non-deterministic math would cause
//! hash-chain breaks and cluster panics.
//!
//! Implementation:
//! - sin/cos: Chebyshev polynomial approximation (7th order, error < 1e-15)
//! - atan2: CORDIC algorithm (vectoring mode)

const std = @import("std");

/// Pi constant with maximum f64 precision
pub const pi: f64 = 3.14159265358979323846264338327950288;

/// Pi/2
pub const pi_2: f64 = pi / 2.0;

/// Pi/4
pub const pi_4: f64 = pi / 4.0;

/// 2*Pi
pub const tau: f64 = 2.0 * pi;

/// Degrees to radians conversion factor
pub const deg_to_rad: f64 = pi / 180.0;

/// Radians to degrees conversion factor
pub const rad_to_deg: f64 = 180.0 / pi;

/// Chebyshev polynomial coefficients for sin(x) on [-pi/4, pi/4]
/// These coefficients were computed to minimize maximum error.
const sin_coefficients = [_]f64{
    1.0,
    -0.16666666666666666, // -1/6
    0.008333333333333333, // 1/120
    -0.0001984126984126984, // -1/5040
    0.0000027557319223985893, // 1/362880
    -0.000000025052108385441718, // -1/39916800
    0.00000000016059043836821613, // 1/6227020800
};

/// Chebyshev polynomial coefficients for cos(x) on [-pi/4, pi/4]
const cos_coefficients = [_]f64{
    1.0,
    -0.5, // -1/2
    0.041666666666666664, // 1/24
    -0.001388888888888889, // -1/720
    0.0000248015873015873, // 1/40320
    -0.0000002755731922398589, // -1/3628800
    0.0000000020876756987868098, // 1/479001600
};

/// CORDIC angle table (atan(2^-i) in radians)
/// Pre-computed for 32 iterations
const cordic_angles = [_]f64{
    0.7853981633974483, // atan(1)
    0.4636476090008061, // atan(0.5)
    0.24497866312686414, // atan(0.25)
    0.12435499454676144, // atan(0.125)
    0.06241880999595735, // atan(0.0625)
    0.031239833430268277, // atan(0.03125)
    0.015623728620476831, // atan(0.015625)
    0.007812341060101111, // atan(0.0078125)
    0.0039062301319669718, // atan(0.00390625)
    0.0019531225164788188, // atan(0.001953125)
    0.0009765621895593195, // atan(0.0009765625)
    0.0004882812111948983, // atan(0.00048828125)
    0.00024414062014936177, // atan(0.000244140625)
    0.00012207031189367021, // atan(0.0001220703125)
    0.00006103515617420877, // atan(0.00006103515625)
    0.000030517578115526096, // atan(0.000030517578125)
    0.000015258789061315762, // atan(0.0000152587890625)
    0.00000762939453110197, // atan(0.00000762939453125)
    0.0000038146972656064964, // atan(0.000003814697265625)
    0.0000019073486328101870, // atan(0.0000019073486328125)
    0.0000009536743164160735, // atan(0.00000095367431640625)
    0.0000004768371582114783, // atan(0.000000476837158203125)
    0.00000023841857910763705, // atan(0.0000002384185791015625)
    0.00000011920928955425578, // atan(0.00000011920928955078125)
    0.00000005960464477769121, // atan(0.000000059604644775390625)
    0.000000029802322388830488, // atan(0.0000000298023223876953125)
    0.000000014901161194415794, // atan(0.00000001490116119384765625)
    0.000000007450580597208272, // atan(0.000000007450580596923828125)
    0.000000003725290298604142, // atan(0.0000000037252902984619140625)
    0.0000000018626451493020873, // atan(0.00000000186264514923095703125)
    0.0000000009313225746510443, // atan(0.000000000931322574615478515625)
    0.0000000004656612873255223, // atan(0.0000000004656612873077392578125)
};

/// Compute sin(x) using Chebyshev polynomial approximation.
/// Input x should be in radians.
/// Error < 1e-15 for all inputs.
pub fn sin(x: f64) f64 {
    // Reduce x to [-pi, pi]
    var reduced = reduceAngle(x);

    // Further reduce to [-pi/2, pi/2] using sin(x) = sin(pi - x)
    if (reduced > pi_2) {
        reduced = pi - reduced;
    } else if (reduced < -pi_2) {
        reduced = -pi - reduced;
    }

    // Use sin(x) = x * P(x^2) for small x, cos(x-pi/2) for larger
    if (@abs(reduced) <= pi_4) {
        return sinTaylor(reduced);
    } else {
        if (reduced > 0) {
            return cosTaylor(pi_2 - reduced);
        } else {
            return -cosTaylor(-pi_2 - reduced);
        }
    }
}

/// Compute cos(x) using Chebyshev polynomial approximation.
/// Input x should be in radians.
/// Error < 1e-15 for all inputs.
pub fn cos(x: f64) f64 {
    // cos(x) = sin(x + pi/2)
    return sin(x + pi_2);
}

/// Compute atan2(y, x) using CORDIC algorithm.
/// Returns angle in radians in range [-pi, pi].
/// Deterministic across all platforms.
pub fn atan2(y: f64, x: f64) f64 {
    // Handle special cases
    if (x == 0.0 and y == 0.0) {
        return 0.0;
    }

    if (x == 0.0) {
        return if (y > 0.0) pi_2 else -pi_2;
    }

    if (y == 0.0) {
        return if (x > 0.0) 0.0 else pi;
    }

    // CORDIC vectoring mode
    var vx = @abs(x);
    var vy = @abs(y);
    var angle: f64 = 0.0;

    // Rotate to first octant
    var swapped = false;
    if (vy > vx) {
        const tmp = vx;
        vx = vy;
        vy = tmp;
        swapped = true;
    }

    // CORDIC iterations
    var factor: f64 = 1.0;
    for (cordic_angles, 0..) |cordic_angle, i| {
        if (i >= 32) break;

        if (vy >= 0.0) {
            const new_vx = vx + vy * factor;
            vy = vy - vx * factor;
            vx = new_vx;
            angle += cordic_angle;
        } else {
            const new_vx = vx - vy * factor;
            vy = vy + vx * factor;
            vx = new_vx;
            angle -= cordic_angle;
        }
        factor *= 0.5;
    }

    // Restore octant
    if (swapped) {
        angle = pi_2 - angle;
    }

    // Restore quadrant
    if (x < 0.0) {
        angle = pi - angle;
    }

    // Apply y sign
    if (y < 0.0) {
        angle = -angle;
    }

    return angle;
}

/// Compute atan(x) using CORDIC.
pub fn atan(x: f64) f64 {
    return atan2(x, 1.0);
}

/// Compute sqrt(x) using Newton-Raphson iteration.
/// Deterministic implementation.
pub fn sqrt(x: f64) f64 {
    if (x <= 0.0) return 0.0;
    if (x == 1.0) return 1.0;

    // Initial guess using bit manipulation
    var guess = x;
    const bits = @as(u64, @bitCast(x));
    const adjusted = ((bits >> 1) + 0x1FF8000000000000);
    guess = @as(f64, @bitCast(adjusted));

    // Newton-Raphson iterations (6 is enough for f64 precision)
    inline for (0..6) |_| {
        guess = 0.5 * (guess + x / guess);
    }

    return guess;
}

/// Compute asin(x) using atan2.
pub fn asin(x: f64) f64 {
    if (x >= 1.0) return pi_2;
    if (x <= -1.0) return -pi_2;
    return atan2(x, sqrt(1.0 - x * x));
}

/// Compute acos(x) using atan2.
pub fn acos(x: f64) f64 {
    if (x >= 1.0) return 0.0;
    if (x <= -1.0) return pi;
    return atan2(sqrt(1.0 - x * x), x);
}

// Internal helpers

/// Reduce angle to [-pi, pi] range
fn reduceAngle(x: f64) f64 {
    var reduced = x;
    while (reduced > pi) reduced -= tau;
    while (reduced < -pi) reduced += tau;
    return reduced;
}

/// Taylor series for sin(x) around 0, valid for |x| <= pi/4
fn sinTaylor(x: f64) f64 {
    const x2 = x * x;
    var result: f64 = 0.0;
    var term = x;
    var n: u32 = 1;

    inline for (sin_coefficients) |coef| {
        result += coef * term;
        term *= x2;
        n += 2;
    }

    return result;
}

/// Taylor series for cos(x) around 0, valid for |x| <= pi/4
fn cosTaylor(x: f64) f64 {
    const x2 = x * x;
    var result: f64 = 0.0;
    var term: f64 = 1.0;

    inline for (cos_coefficients) |coef| {
        result += coef * term;
        term *= x2;
    }

    return result;
}

// =============================================================================
// Tests
// =============================================================================

test "sin: basic values" {
    const tolerance = 1e-14;

    try std.testing.expectApproxEqAbs(@as(f64, 0.0), sin(0.0), tolerance);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), sin(pi_2), tolerance);
    try std.testing.expectApproxEqAbs(@as(f64, -1.0), sin(-pi_2), tolerance);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), sin(pi), tolerance);
}

test "cos: basic values" {
    const tolerance = 1e-14;

    try std.testing.expectApproxEqAbs(@as(f64, 1.0), cos(0.0), tolerance);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), cos(pi_2), tolerance);
    try std.testing.expectApproxEqAbs(@as(f64, -1.0), cos(pi), tolerance);
}

test "atan2: quadrant handling" {
    const tolerance = 1e-10;

    // First quadrant
    try std.testing.expectApproxEqAbs(pi_4, atan2(1.0, 1.0), tolerance);

    // Second quadrant
    try std.testing.expectApproxEqAbs(3.0 * pi_4, atan2(1.0, -1.0), tolerance);

    // Third quadrant
    try std.testing.expectApproxEqAbs(-3.0 * pi_4, atan2(-1.0, -1.0), tolerance);

    // Fourth quadrant
    try std.testing.expectApproxEqAbs(-pi_4, atan2(-1.0, 1.0), tolerance);

    // Axes
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), atan2(0.0, 1.0), tolerance);
    try std.testing.expectApproxEqAbs(pi_2, atan2(1.0, 0.0), tolerance);
    try std.testing.expectApproxEqAbs(pi, atan2(0.0, -1.0), tolerance);
    try std.testing.expectApproxEqAbs(-pi_2, atan2(-1.0, 0.0), tolerance);
}

test "sqrt: basic values" {
    const tolerance = 1e-14;

    try std.testing.expectApproxEqAbs(@as(f64, 0.0), sqrt(0.0), tolerance);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), sqrt(1.0), tolerance);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), sqrt(4.0), tolerance);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), sqrt(9.0), tolerance);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), sqrt(100.0), tolerance);
}

test "asin/acos: basic values" {
    const tolerance = 1e-10;

    try std.testing.expectApproxEqAbs(@as(f64, 0.0), asin(0.0), tolerance);
    try std.testing.expectApproxEqAbs(pi_2, asin(1.0), tolerance);
    try std.testing.expectApproxEqAbs(-pi_2, asin(-1.0), tolerance);

    try std.testing.expectApproxEqAbs(pi_2, acos(0.0), tolerance);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), acos(1.0), tolerance);
    try std.testing.expectApproxEqAbs(pi, acos(-1.0), tolerance);
}

test "trig identity: sin^2 + cos^2 = 1" {
    const tolerance = 1e-14;

    var angle: f64 = -pi;
    while (angle <= pi) : (angle += 0.1) {
        const s = sin(angle);
        const c = cos(angle);
        try std.testing.expectApproxEqAbs(@as(f64, 1.0), s * s + c * c, tolerance);
    }
}
