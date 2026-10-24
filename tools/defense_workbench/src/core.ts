import * as h3 from "h3-js";

export interface RawGpsFix {
  lat: number;
  lon: number;
  ele: number;
  accuracyM: number;
  speedMps: number;
  monotonicMs: number;
  isoUtc: string;
}

export function haversineMeters(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const R = 6371000;
  const toRad = (deg: number) => (deg * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLon = toRad(lon2 - lon1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

export function shouldAcceptGpsFix(prev: RawGpsFix | null, next: RawGpsFix): boolean {
  if (next.accuracyM > 25.0) return false;
  if (!prev) return true;
  const dtMs = next.monotonicMs - prev.monotonicMs;
  if (dtMs <= 0) return false;
  const distM = haversineMeters(prev.lat, prev.lon, next.lat, next.lon);
  const impliedSpeedMps = distM / (dtMs / 1000);
  if (impliedSpeedMps > 25.0) return false; // GPS teleport spike
  return dtMs >= 3000 || distM >= 5.0;
}

export function classifyDynamicMet(speedMps: number, cadenceSpm: number): number {
  if (speedMps < 0.4 && cadenceSpm < 35) return 1.3;
  const kmh = speedMps * 3.6;
  if (kmh < 4.0) return 2.8;
  if (kmh <= 6.5) return 4.3;
  if (kmh <= 10.0) return 8.0;
  return 11.0;
}

export function computeKcalBurn(met: number, weightKg: number, durationMin: number): number {
  if (weightKg <= 0 || durationMin <= 0) return 0;
  return ((met * 3.5 * weightKg) / 200) * durationMin;
}

export function computeHexEffortPoints(steps: number, distanceM: number, activeDwellS: number): number {
  const raw = 1.0 * steps + 0.35 * distanceM + 0.05 * activeDwellS;
  return Math.min(600, Math.round(raw * 100) / 100);
}

export function cellForCoordinate(lat: number, lon: number): { h3Res9: string; parentRes5: string } {
  const h3Res9 = h3.latLngToCell(lat, lon, 9);
  const parentRes5 = h3.cellToParent(h3Res9, 5);
  return { h3Res9, parentRes5 };
}
