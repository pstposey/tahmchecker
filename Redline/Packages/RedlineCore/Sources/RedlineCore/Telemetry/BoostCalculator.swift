/// Boost as gauge pressure.
///
///     boost_kPa = MAP_kPa − BARO_kPa
///
/// Negative = manifold vacuum, 0 = atmospheric, positive = boost.
///
/// Inputs: PID 0B (MAP, absolute) and PID 33 (BARO, absolute), both from
/// the ECU. Redline never substitutes sea-level pressure (101.325 kPa) for
/// BARO: at Colorado elevations that would under-read boost by ~15–20 kPa
/// (2–3 psi). If BARO is unsupported or no valid sample has arrived yet,
/// boost is unavailable — MAP is still shown separately as absolute
/// pressure, clearly labelled.
///
/// BARO caching: atmospheric pressure changes slowly relative to MAP, so the
/// most recent valid BARO sample is reused for every MAP sample. Its age is
/// carried on the boost sample's timing for traceability.
///
/// Limitations: PID 0B has 1 kPa resolution and a 255 kPa absolute ceiling;
/// boost therefore has ±1 kPa (≈0.15 psi) quantization, and cannot exceed
/// 255 − BARO kPa. Some ECUs compute BARO from MAP at key-on rather than a
/// dedicated sensor; either way it is ECU-reported.
public enum BoostCalculator {
    public static func gaugePressure(manifoldAbsolute mapKPa: Double, barometric baroKPa: Double) -> Double {
        mapKPa - baroKPa
    }
}
