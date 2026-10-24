import 'package:flutter/material.dart';
import 'package:terrasteps_fitness/terrasteps_fitness.dart';

import '../../services/workout_tracker_controller.dart';

/// Deliverable 2: Hardware Step Counter, Dynamic METs Calorie Burn & Live
/// Workout Control Screen.
class FitnessTrackerScreen extends StatelessWidget {
  final WorkoutTrackerController tracker;

  const FitnessTrackerScreen({super.key, required this.tracker});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: tracker,
      builder: (context, _) {
        final snap = tracker.liveSnapshot;
        final goal = tracker.profile.dailyStepGoal;
        final goalProgress = (snap.measuredSteps / (goal <= 0 ? 8000 : goal))
            .clamp(0.0, 1.0);

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (tracker.interruptionNotice != null)
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF451A03),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFF59E0B)),
                ),
                child: Text(
                  tracker.interruptionNotice!,
                  style: const TextStyle(color: Color(0xFFFEF3C7), fontSize: 12),
                ),
              ),

            // Step Goal Ring Card
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF0F172A), Color(0xFF1E293B)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFF334155)),
              ),
              child: Column(
                children: [
                  SizedBox(
                    height: 150,
                    width: 150,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        SizedBox(
                          height: 140,
                          width: 140,
                          child: CircularProgressIndicator(
                            value: goalProgress,
                            strokeWidth: 11,
                            backgroundColor: const Color(0xFF334155),
                            color: const Color(0xFF10B981),
                          ),
                        ),
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '${snap.measuredSteps}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 30,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            Text(
                              'of $goal steps',
                              style: const TextStyle(
                                color: Color(0xFF94A3B8),
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    children: [
                      _pill(
                        'MET ${snap.currentMet.toStringAsFixed(1)} (${_intensityLabel(snap.intensity)})',
                        const Color(0xFF38BDF8),
                      ),
                      _pill(
                        'GPS Est. ${snap.estimatedSteps} steps (separate)',
                        const Color(0xFF94A3B8),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 14),

            // 4-Metric Grid
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 1.65,
              children: [
                _metricCard(
                  icon: Icons.local_fire_department,
                  color: const Color(0xFFF97316),
                  label: 'Active Calories',
                  value: '${snap.caloriesBurnedKcal.toStringAsFixed(1)} kcal',
                ),
                _metricCard(
                  icon: Icons.straighten,
                  color: const Color(0xFF10B981),
                  label: 'GPS Distance',
                  value: '${(snap.distanceMeters / 1000.0).toStringAsFixed(2)} km',
                ),
                _metricCard(
                  icon: Icons.timer_outlined,
                  color: const Color(0xFF38BDF8),
                  label: 'Active Duration',
                  value: _formatMs(snap.activeDurationMs),
                ),
                _metricCard(
                  icon: Icons.speed,
                  color: const Color(0xFFA78BFA),
                  label: 'Cadence / Speed',
                  value:
                      '${snap.cadenceSpm} spm • ${(snap.currentSpeedMps * 3.6).toStringAsFixed(1)} km/h',
                ),
              ],
            ),

            const SizedBox(height: 18),

            // Primary Workout Controls
            if (tracker.lifecycle == WorkoutLifecycleState.idle) ...[
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF10B981),
                  foregroundColor: Colors.black,
                  minimumSize: const Size.fromHeight(52),
                ),
                onPressed: () => tracker.startHardwareWorkout(),
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text(
                  'Start Live Hardware GPS + Step Workout',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(46),
                ),
                onPressed: () =>
                    tracker.startSimulatedDefenseSession(vehicleCheatDemo: false),
                icon: const Icon(Icons.directions_walk),
                label: const Text('30% Defense Demo: Simulate Valid Campus Walk'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(46),
                  foregroundColor: const Color(0xFFF97316),
                ),
                onPressed: () =>
                    tracker.startSimulatedDefenseSession(vehicleCheatDemo: true),
                icon: const Icon(Icons.directions_car),
                label: const Text('30% Defense Demo: Simulate 48 km/h Car Spoof'),
              ),
            ] else ...[
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(50),
                      ),
                      onPressed: tracker.lifecycle == WorkoutLifecycleState.recording
                          ? tracker.pauseWorkout
                          : tracker.resumeWorkout,
                      icon: Icon(
                        tracker.lifecycle == WorkoutLifecycleState.recording
                            ? Icons.pause
                            : Icons.play_arrow,
                      ),
                      label: Text(
                        tracker.lifecycle == WorkoutLifecycleState.recording
                            ? 'Pause'
                            : 'Resume',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFEF4444),
                        minimumSize: const Size.fromHeight(50),
                      ),
                      onPressed: () async {
                        final path = await tracker.finishAndExportGpx();
                        if (context.mounted && path != null) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Saved GPX 1.1: $path')),
                          );
                        }
                      },
                      icon: const Icon(Icons.stop_circle_outlined),
                      label: const Text('Finish & Save GPX'),
                    ),
                  ),
                ],
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _pill(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        text,
        style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _metricCard({
    required IconData icon,
    required Color color,
    required String label,
    required String value,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF1E293B)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              Icon(icon, size: 17, color: color),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  static String _intensityLabel(ActivityIntensity i) {
    switch (i) {
      case ActivityIntensity.stationary:
        return 'Stationary';
      case ActivityIntensity.slowWalk:
        return 'Slow Walk';
      case ActivityIntensity.briskWalk:
        return 'Brisk Walk';
      case ActivityIntensity.jogging:
        return 'Jogging';
      case ActivityIntensity.fastRunning:
        return 'Fast Run';
    }
  }

  static String _formatMs(int ms) {
    final totalSec = ms ~/ 1000;
    final m = (totalSec ~/ 60).toString().padLeft(2, '0');
    final s = (totalSec % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
