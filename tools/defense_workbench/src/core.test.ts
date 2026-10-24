import { describe, it, expect } from "vitest";
import {
  shouldAcceptGpsFix,
  classifyDynamicMet,
  computeKcalBurn,
  computeHexEffortPoints,
  cellForCoordinate,
} from "./core";

describe("TerraSteps 30% Milestone Core Engine", () => {
  it("Deliverable 1: rejects low-accuracy (>25m) and teleport spikes while sampling >=3s or >=5m", () => {
    const base = {
      lat: 34.158672,
      lon: 73.259642,
      ele: 1255,
      accuracyM: 4.5,
      speedMps: 1.4,
      monotonicMs: 1000,
      isoUtc: "2026-10-24T10:00:00Z",
    };
    expect(shouldAcceptGpsFix(null, { ...base, accuracyM: 32.0 })).toBe(false);
    expect(shouldAcceptGpsFix(null, base)).toBe(true);
    // Too soon (<3s) and too close (<5m)
    expect(
      shouldAcceptGpsFix(base, {
        ...base,
        lat: 34.158675,
        monotonicMs: 2000,
      }),
    ).toBe(false);
    // Valid 4s sample
    expect(
      shouldAcceptGpsFix(base, {
        ...base,
        lat: 34.15872,
        monotonicMs: 5000,
      }),
    ).toBe(true);
    // GPS teleport spike (5km in 1 second)
    expect(
      shouldAcceptGpsFix(base, {
        ...base,
        lat: 34.205,
        monotonicMs: 2000,
      }),
    ).toBe(false);
  });

  it("Deliverable 2: computes dynamic MET tiers and standard kcal formula", () => {
    expect(classifyDynamicMet(0.0, 0)).toBe(1.3);
    expect(classifyDynamicMet(0.8, 75)).toBe(2.8); // 2.88 km/h casual stroll
    expect(classifyDynamicMet(1.5, 112)).toBe(4.3); // 5.4 km/h brisk walk
    expect(classifyDynamicMet(2.4, 155)).toBe(8.0); // 8.64 km/h jog
    expect(classifyDynamicMet(3.2, 172)).toBe(11.0); // 11.52 km/h run

    // 30 min brisk walk (MET 4.3) for 70 kg person => 4.3 * 3.5 * 70 / 200 * 30 = 158.025 kcal
    expect(computeKcalBurn(4.3, 70, 30)).toBeCloseTo(158.025, 3);
  });

  it("Deliverable 3: maps Abbottabad campus to H3 Res-9 + Res-5 parent and caps effort at 600", () => {
    const mapped = cellForCoordinate(34.158672, 73.259642);
    expect(mapped.h3Res9).toBe("89209a0aa73ffff");
    expect(mapped.parentRes5).toBe("85209a0bfffffff");

    expect(computeHexEffortPoints(200, 140, 100)).toBe(254);
    expect(computeHexEffortPoints(900, 500, 300)).toBe(600);
  });
});
