//
//  DMath.swift
//  TrafficEngine
//
//  Deterministic, platform-independent transcendental functions.
//
//  Why not Foundation/libm? glibc (Linux CI) and Darwin's libm are both
//  accurate, but they are not bit-identical. A simulation whose trace hash must
//  match across Linux, macOS and iOS can only use operations that IEEE-754
//  defines exactly (+, −, ×, ÷, √). These routines are built only from those
//  operations, so every platform produces the same bits.
//
//  Accuracy is ≈1 ulp in practice. The polynomials are the classic fdlibm
//  (Sun Microsystems, 1993) minimax kernels.
//

public enum DMath {

    public static let pi = 3.141592653589793
    public static let twoPi = 6.283185307179586
    public static let halfPi = 1.5707963267948966
    static let ln2Hi = 6.93147180369123816490e-01
    static let ln2Lo = 1.90821492927058770002e-10
    static let invLn2 = 1.44269504088896338700e+00

    // MARK: - sin / cos

    // π/2 split into a high part (33 significant bits) and a tail, so that
    // n·pio2Hi is exact for |n| < 2^20 (Cody–Waite reduction).
    private static let pio2Hi = 1.57079632673412561417e+00
    private static let pio2Lo = 6.07710050650619224932e-11
    private static let twoOverPi = 6.36619772367581382433e-01

    @inline(__always)
    private static func kernelSin(_ x: Double) -> Double {
        let z = x * x
        let r = 8.33333333332248946124e-03 + z * (-1.98412698298579493134e-04 + z * (2.75573137070700676789e-06
              + z * (-2.50507602534068634195e-08 + z * 1.58969099521155010221e-10)))
        return x + x * z * (-1.66666666666666324348e-01 + z * r)
    }

    @inline(__always)
    private static func kernelCos(_ x: Double) -> Double {
        let z = x * x
        let r = z * (4.16666666666666019037e-02 + z * (-1.38888888888741095749e-03 + z * (2.48015872894767294178e-05
              + z * (-2.75573143513906633035e-07 + z * (2.08757232129817482790e-09 + z * -1.13596475577881948265e-11)))))
        let hz = 0.5 * z
        let w = 1.0 - hz
        return w + (((1.0 - w) - hz) + z * r)
    }

    /// Reduce `x` to `r` in [-π/4, π/4] and the quadrant `n mod 4`.
    @inline(__always)
    private static func reduce(_ x: Double) -> (r: Double, q: Int) {
        if x.magnitude <= 0.7853981633974483 { return (x, 0) }
        let n = (x * twoOverPi).rounded(.toNearestOrEven)
        let r = (x - n * pio2Hi) - n * pio2Lo
        let q = Int(n) & 3
        return (r, q)
    }

    public static func sin(_ x: Double) -> Double {
        guard x.isFinite else { return .nan }
        let (r, q) = reduce(x)
        switch q {
        case 0: return kernelSin(r)
        case 1: return kernelCos(r)
        case 2: return -kernelSin(r)
        default: return -kernelCos(r)
        }
    }

    public static func cos(_ x: Double) -> Double {
        guard x.isFinite else { return .nan }
        let (r, q) = reduce(x)
        switch q {
        case 0: return kernelCos(r)
        case 1: return -kernelSin(r)
        case 2: return -kernelCos(r)
        default: return kernelSin(r)
        }
    }

    public static func tan(_ x: Double) -> Double { sin(x) / cos(x) }

    // MARK: - atan / atan2

    private static let atanHi: [Double] = [
        4.63647609000806093515e-01, 7.85398163397448278999e-01,
        9.82793723247329054082e-01, 1.57079632679489655800e+00
    ]
    private static let atanLo: [Double] = [
        2.26987774529616870924e-17, 3.06161699786838301793e-17,
        1.39033110312309984516e-17, 6.12323399573676603587e-17
    ]

    public static func atan(_ v: Double) -> Double {
        if v.isNaN { return v }
        if v.isInfinite { return v > 0 ? halfPi : -halfPi }
        let negative = v < 0
        var x = v.magnitude
        let id: Int
        if x < 0.4375 {
            id = -1
        } else if x < 1.1875 {
            if x < 0.6875 { id = 0; x = (2.0 * x - 1.0) / (2.0 + x) }
            else { id = 1; x = (x - 1.0) / (x + 1.0) }
        } else if x < 2.4375 {
            id = 2; x = (x - 1.5) / (1.0 + 1.5 * x)
        } else {
            id = 3; x = -1.0 / x
        }
        let z = x * x
        let w = z * z
        let s1 = z * (3.33333333333329318027e-01 + w * (1.42857142725034663711e-01 + w * (9.09088713343650656196e-02
               + w * (6.66107313738753120669e-02 + w * (4.97687799461593236017e-02 + w * 1.62858201153657823623e-02)))))
        let s2 = w * (-1.99999999998764832476e-01 + w * (-1.11111104054623557880e-01 + w * (-7.69187620504482999495e-02
               + w * (-5.83357013379057348645e-02 + w * -3.65315727442169155270e-02))))
        let result: Double
        if id < 0 {
            result = x - x * (s1 + s2)
        } else {
            result = atanHi[id] - ((x * (s1 + s2) - atanLo[id]) - x)
        }
        return negative ? -result : result
    }

    /// Angle of the vector (x, y) in (-π, π].
    public static func atan2(_ y: Double, _ x: Double) -> Double {
        if x.isNaN || y.isNaN { return .nan }
        if x == 0 {
            if y > 0 { return halfPi }
            if y < 0 { return -halfPi }
            return 0
        }
        if y == 0 { return x > 0 ? 0 : pi }
        let ax = x.magnitude, ay = y.magnitude
        // Use the smaller ratio for accuracy.
        var a: Double
        if ay <= ax {
            a = atan(ay / ax)
        } else {
            a = halfPi - atan(ax / ay)
        }
        if x < 0 { a = pi - a }
        return y < 0 ? -a : a
    }

    public static func asin(_ x: Double) -> Double {
        let c = x.clamped(to: -1...1)
        return atan2(c, (1 - c * c).squareRoot())
    }

    public static func acos(_ x: Double) -> Double {
        let c = x.clamped(to: -1...1)
        return atan2((1 - c * c).squareRoot(), c)
    }

    // MARK: - exp / log / pow

    public static func exp(_ x: Double) -> Double {
        if x.isNaN { return x }
        if x > 709.78 { return .infinity }
        if x < -745.0 { return 0 }
        let k = (x * invLn2).rounded(.toNearestOrEven)
        let hi = x - k * ln2Hi
        let lo = k * ln2Lo
        let r = hi - lo
        // Taylor series of e^r for |r| ≤ ln2/2 ≈ 0.347; 14 terms → error < 1e-17.
        var term = 1.0
        var sum = 1.0
        var i = 1.0
        while i <= 14 {
            term = term * r / i
            sum += term
            i += 1
        }
        return scale2(sum, Int(k))
    }

    /// x · 2^k using only exact operations.
    @inline(__always)
    static func scale2(_ x: Double, _ k: Int) -> Double {
        var result = x
        var k = k
        // Split into steps that stay within the normal exponent range.
        while k > 1000 { result *= Double(sign: .plus, exponent: 1000, significand: 1); k -= 1000 }
        while k < -1000 { result *= Double(sign: .plus, exponent: -1000, significand: 1); k += 1000 }
        return result * Double(sign: .plus, exponent: k, significand: 1)
    }

    public static func log(_ x: Double) -> Double {
        if x.isNaN || x < 0 { return .nan }
        if x == 0 { return -.infinity }
        if x.isInfinite { return x }
        var m = x.significand          // [1, 2)
        var e = Int(x.exponent)
        if m > 1.4142135623730951 { m *= 0.5; e += 1 }
        let f = (m - 1) / (m + 1)       // |f| ≤ 0.1716
        let f2 = f * f
        // 2·atanh(f) = 2(f + f³/3 + f⁵/5 + …); 11 terms → error < 1e-17.
        var term = f
        var sum = f
        var k = 3.0
        while k <= 23 {
            term *= f2
            sum += term / k
            k += 2
        }
        let de = Double(e)
        return (2 * sum + de * ln2Lo) + de * ln2Hi
    }

    public static func log10(_ x: Double) -> Double { log(x) * 0.43429448190325182765 }

    public static func pow(_ base: Double, _ exponent: Double) -> Double {
        if exponent == 0 { return 1 }
        if exponent == 1 { return base }
        if exponent == 2 { return base * base }
        if exponent == 4 { let b2 = base * base; return b2 * b2 }
        if exponent == 0.5 { return base.squareRoot() }
        if base == 0 { return exponent > 0 ? 0 : .infinity }
        if base < 0 {
            // Only integral exponents are defined for negative bases.
            guard exponent.rounded() == exponent else { return .nan }
            let r = exp(exponent * log(-base))
            return Int(exponent.magnitude.truncatingRemainder(dividingBy: 2)) == 1 ? -r : r
        }
        return exp(exponent * log(base))
    }

    public static func tanh(_ x: Double) -> Double {
        if x > 20 { return 1 }
        if x < -20 { return -1 }
        let e2 = exp(2 * x)
        return (e2 - 1) / (e2 + 1)
    }

    public static func hypot(_ x: Double, _ y: Double) -> Double { (x * x + y * y).squareRoot() }

    /// Wrap an angle into (-π, π].
    public static func wrapAngle(_ a: Double) -> Double {
        var r = a.truncatingRemainder(dividingBy: twoPi)
        if r <= -pi { r += twoPi }
        if r > pi { r -= twoPi }
        return r
    }

    /// Signed smallest difference b − a in (-π, π].
    public static func angleDifference(_ a: Double, _ b: Double) -> Double { wrapAngle(b - a) }
}

public extension Double {
    /// Clamp a value into a closed range.
    @inlinable func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }

    func nonNegativeMod(_ m: Double) -> Double {
        let r = truncatingRemainder(dividingBy: m)
        return r < 0 ? r + m : r
    }
}

/// Quintic smoothstep 6t⁵ − 15t⁴ + 10t³: zero velocity *and* acceleration at
/// both ends. Used for lateral lane-change profiles.
@inlinable
public func smootherStep(_ t: Double) -> Double {
    let x = t.clamped(to: 0...1)
    return x * x * x * (x * (x * 6 - 15) + 10)
}

/// Derivative of `smootherStep` with respect to t.
@inlinable
public func smootherStepDerivative(_ t: Double) -> Double {
    let x = t.clamped(to: 0...1)
    return 30 * x * x * (x - 1) * (x - 1)
}
