import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../constants.dart';
import '../state/project_state.dart';

class TopBar extends StatelessWidget {
  const TopBar({super.key});
  @override
  Widget build(BuildContext context) {
    final state = context.watch<ProjectState>();
    return Container(
      height: 40, color: const Color(0xFF222222), padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children:[
          Text("${state.projectName}${state.activeFilePath == null ? '*' : ''} - Node Writer", style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white70)),
          const SizedBox(width: 20), const VerticalDivider(color: Colors.black, width: 20),
          _MenuButton(label: "New", onTap: () => state.newProject()),
          _MenuButton(label: "Open", onTap: () => state.loadProject()),
          _MenuButton(label: "Save", onTap: () => state.saveProject()),
          _MenuButton(label: "Save As", onTap: () => state.saveAsProject()),
          const VerticalDivider(color: Colors.black, width: 20),
          _MenuButton(label: "Undo", onTap: () => state.undo()),
          const VerticalDivider(color: Colors.black, width: 20),
          _MenuButton(label: "Copy", onTap: () => state.copySelection()),
          _MenuButton(label: "Paste", onTap: () => state.paste()),
          const VerticalDivider(color: Colors.black, width: 20),
          _MenuButton(label: "About", onTap: () => _showAboutDialog(context)),
          const Spacer(),
          IconButton(icon: const Icon(Icons.settings, size: 18), tooltip: "Settings", onPressed: () => _showSettingsDialog(context, state)),
          IconButton(icon: const Icon(Icons.delete, size: 18), onPressed: () => state.deleteSelected(), tooltip: "Delete Selected"),
        ],
      ),
    );
  }

  void _showAboutDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        contentPadding: const EdgeInsets.only(top: 32, bottom: 24, left: 24, right: 24),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children:[
            Image.asset('assets/logo.png', height: 200, errorBuilder: (context, error, stackTrace) => const Icon(Icons.account_tree, size: 100, color: kAccentColor)), 
            const SizedBox(height: 5),
            const Text("Node Writer 1.6", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white)),
            const SizedBox(height: 8),
            const Text("by Nathaniel Westveer", style: TextStyle(fontSize: 14, color: Colors.white70)),
          ],
        ),
        actions:[TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Close", style: TextStyle(color: kAccentColor)))],
      ),
    );
  }

  void _showSettingsDialog(BuildContext context, ProjectState state) {
    showDialog(
      context: context,
      builder: (ctx) {
        String selected = state.unitLabel;
        return StatefulBuilder(
          builder: (context, setState) => AlertDialog(
            title: const Text("Project Settings"),
            content: Column(
              mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
              children:[
                const Text("What do you call a node?"), const SizedBox(height: 10),
                DropdownButton<String>(
                  value: selected, isExpanded: true,
                  items: ["Scene", "Passage", "Paragraph", "Section", "Beat", "Card", "Header"].map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
                  onChanged: (val) {
                    if (val != null) { setState(() => selected = val); state.setUnitLabel(val); }
                  },
                ),
              ],
            ),
            actions:[TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Done"))],
          ),
        );
      },
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
      child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), child: Text(label, style: const TextStyle(color: Colors.white))),
    );
  }
}