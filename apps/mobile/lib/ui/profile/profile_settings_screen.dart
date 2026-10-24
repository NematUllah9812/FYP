import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:terrasteps_fitness/terrasteps_fitness.dart';

import '../../data/remote/drive_asset_service.dart';
import '../../services/workout_tracker_controller.dart';

/// User Profile Settings (MET weight/height/step goal), Supabase Auth Sign-In,
/// and Google Drive Offline Asset Pack downloader.
class ProfileSettingsScreen extends StatefulWidget {
  final WorkoutTrackerController tracker;
  final DriveAssetService driveService;

  const ProfileSettingsScreen({
    super.key,
    required this.tracker,
    required this.driveService,
  });

  @override
  State<ProfileSettingsScreen> createState() => _ProfileSettingsScreenState();
}

class _ProfileSettingsScreenState extends State<ProfileSettingsScreen> {
  late final TextEditingController _weightCtrl;
  late final TextEditingController _heightCtrl;
  late final TextEditingController _goalCtrl;
  final TextEditingController _emailCtrl = TextEditingController();
  final TextEditingController _passwordCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    final p = widget.tracker.profile;
    _weightCtrl = TextEditingController(text: p.weightKg.toStringAsFixed(1));
    _heightCtrl = TextEditingController(text: p.heightCm.toStringAsFixed(0));
    _goalCtrl = TextEditingController(text: p.dailyStepGoal.toString());
  }

  @override
  void dispose() {
    _weightCtrl.dispose();
    _heightCtrl.dispose();
    _goalCtrl.dispose();
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _saveProfile() async {
    final current = widget.tracker.profile;
    final updated = current.copyWith(
      weightKg: double.tryParse(_weightCtrl.text) ?? current.weightKg,
      heightCm: double.tryParse(_heightCtrl.text) ?? current.heightCm,
      dailyStepGoal: int.tryParse(_goalCtrl.text) ?? current.dailyStepGoal,
    );
    await widget.tracker.updateUserProfile(updated);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Saved offline MET & stride profile to Drift SQLite.')),
    );
  }

  Future<void> _signInOrSignUp({required bool isSignUp}) async {
    try {
      final auth = Supabase.instance.client.auth;
      if (isSignUp) {
        await auth.signUp(
          email: _emailCtrl.text.trim(),
          password: _passwordCtrl.text,
        );
      } else {
        await auth.signInWithPassword(
          email: _emailCtrl.text.trim(),
          password: _passwordCtrl.text,
        );
      }
      if (!mounted) return;
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Supabase Auth session active!')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Auth error: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    User? authUser;
    try {
      authUser = Supabase.instance.client.auth.currentUser;
    } catch (_) {}

    final p = widget.tracker.profile;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Image.asset(
            'assets/images/hero_banner.jpg',
            height: 120,
            width: double.infinity,
            fit: BoxFit.cover,
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          'Anthropometrics & MET Calibration (Offline Drift DB)',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _weightCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Weight (kg)',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _heightCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Height (cm)',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _goalCtrl,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: 'Daily Step Goal',
            helperText:
                'Walking stride: ${p.walkingStrideMeters.toStringAsFixed(2)} m • Running stride: ${p.runningStrideMeters.toStringAsFixed(2)} m',
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 10),
        FilledButton(
          onPressed: _saveProfile,
          child: const Text('Save Local Profile'),
        ),
        const Divider(height: 32),
        const Text(
          'Supabase Competitive Account',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        if (authUser != null)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.verified_user, color: Color(0xFF10B981)),
            title: Text(authUser.email ?? authUser.id),
            subtitle: const Text('Signed in to TerraSteps Supabase'),
            trailing: TextButton(
              onPressed: () async {
                await Supabase.instance.client.auth.signOut();
                setState(() {});
              },
              child: const Text('Sign Out'),
            ),
          )
        else ...[
          TextField(
            controller: _emailCtrl,
            decoration: const InputDecoration(
              labelText: 'Email',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _passwordCtrl,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Password',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: FilledButton.tonal(
                  onPressed: () => _signInOrSignUp(isSignUp: false),
                  child: const Text('Sign In'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _signInOrSignUp(isSignUp: true),
                  child: const Text('Create Account'),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
