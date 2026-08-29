import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../constants.dart';
import '../state/project_state.dart';
import 'dialogs/settings_dialog.dart';

/// File and edit commands, plus the only place the application tells the
/// author whether their work is actually on disk.
class TopBar extends StatelessWidget {
  const TopBar({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ProjectState>();
    return Container(
      height: 40,
      color: const Color(0xFF222222),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          Text(
            projectTitle(state),
            style: const TextStyle(
                fontWeight: FontWeight.bold, color: Colors.white70),
          ),
          if (state.isDirty)
            const Padding(
              padding: EdgeInsets.only(left: 8),
              child: Tooltip(
                message: 'Unsaved changes',
                child: Icon(Icons.circle, size: 8, color: kAccentColor),
              ),
            ),
          const SizedBox(width: 20),
          const VerticalDivider(color: Colors.black, width: 20),
          _MenuButton(label: "New", onTap: () => newProject(context)),
          _MenuButton(label: "Open", onTap: () => openProject(context)),
          _MenuButton(label: "Save", onTap: () => saveProject(context)),
          _MenuButton(label: "Save As", onTap: () => saveProjectAs(context)),
          const VerticalDivider(color: Colors.black, width: 20),
          _MenuButton(label: "Undo", onTap: () => state.undo()),
          const VerticalDivider(color: Colors.black, width: 20),
          _MenuButton(label: "Copy", onTap: () => state.copySelection()),
          _MenuButton(label: "Paste", onTap: () => state.paste()),
          const VerticalDivider(color: Colors.black, width: 20),
          _MenuButton(label: "About", onTap: () => _showAboutDialog(context)),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.settings, size: 18),
            tooltip: "Settings",
            onPressed: () => _showSettingsDialog(context, state),
          ),
          IconButton(
            icon: const Icon(Icons.delete, size: 18),
            onPressed: () => state.deleteSelected(),
            tooltip: "Delete Selected",
          ),
        ],
      ),
    );
  }

  static String projectTitle(ProjectState state) {
    final saved = state.activeFilePath != null;
    return "${state.projectName}${saved ? '' : ' (unsaved)'} - Node Writer";
  }

  // -------------------------------------------------------------------
  // File commands
  //
  // Every one of these reports its outcome. A save that silently fails is
  // indistinguishable from a save that worked, which is the worst possible
  // failure mode for a writing tool.
  // -------------------------------------------------------------------

  static void _report(BuildContext context, String message,
      {bool error = false}) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: error ? Colors.red.shade900 : null,
          duration: Duration(seconds: error ? 6 : 2),
        ),
      );
  }

  static Future<void> saveProject(BuildContext context) async {
    final state = context.read<ProjectState>();
    final result = await state.saveProject();
    if (!context.mounted || result.cancelled) return;
    if (result.succeeded) {
      _report(context, 'Saved ${result.path}');
    } else {
      _report(context, result.error!, error: true);
    }
  }

  static Future<void> saveProjectAs(BuildContext context) async {
    final state = context.read<ProjectState>();
    final result = await state.saveAsProject();
    if (!context.mounted || result.cancelled) return;
    if (result.succeeded) {
      _report(context, 'Saved ${result.path}');
    } else {
      _report(context, result.error!, error: true);
    }
  }

  static Future<void> openProject(BuildContext context) async {
    if (!await _confirmDiscard(context, 'Open another project')) return;
    if (!context.mounted) return;
    final state = context.read<ProjectState>();
    final result = await state.loadProject();
    if (!context.mounted || result.cancelled) return;
    if (!result.succeeded) _report(context, result.error!, error: true);
  }

  static Future<void> newProject(BuildContext context) async {
    if (!await _confirmDiscard(context, 'Start a new project')) return;
    if (!context.mounted) return;
    context.read<ProjectState>().newProject();
  }

  /// Returns true when it is safe to throw away the current document.
  static Future<bool> _confirmDiscard(BuildContext context, String action) async {
    final state = context.read<ProjectState>();
    if (!state.isDirty) return true;

    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unsaved changes'),
        content: Text(
          '${state.projectName} has changes that are not on disk. '
          '$action and lose them?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              final result = await state.saveProject();
              if (!ctx.mounted) return;
              Navigator.pop(ctx, result.succeeded);
            },
            child: const Text('Save first'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Discard',
                style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    return proceed ?? false;
  }

  void _showAboutDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        contentPadding:
            const EdgeInsets.only(top: 32, bottom: 24, left: 24, right: 24),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              'assets/logo.png',
              height: 200,
              errorBuilder: (context, error, stackTrace) =>
                  const Icon(Icons.account_tree, size: 100, color: kAccentColor),
            ),
            const SizedBox(height: 5),
            const Text(
              "Node Writer 1.7",
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.white),
            ),
            const SizedBox(height: 8),
            const Text("by Nathaniel Westveer",
                style: TextStyle(fontSize: 14, color: Colors.white70)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Close", style: TextStyle(color: kAccentColor)),
          )
        ],
      ),
    );
  }

  void _showSettingsDialog(BuildContext context, ProjectState state) {
    showDialog(
      context: context,
      builder: (_) => SettingsDialog(projectState: state),
    );
  }
}

class _MenuButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _MenuButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(label, style: const TextStyle(color: Colors.white)),
      ),
    );
  }
}
