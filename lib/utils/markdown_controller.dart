import 'package:flutter/material.dart';

import '../models/authorial_constraint.dart';

/// Node Writer's editor controller layers Markdown syntax, authorial locks,
/// TTS playback, and find-in-node matches.
class MarkdownSyntaxController extends TextEditingController {
  static const int _minSearchLength = 2;

  int _playbackStart = -1;
  int _playbackEnd = -1;
  String _searchQuery = '';
  int _activeMatchOffset = -1;
  List<AuthorConstraint> _authorConstraints = <AuthorConstraint>[];


  void setAuthorConstraints(List<AuthorConstraint> constraints) {
    final next = constraints
        .map((c) => AuthorConstraint(
              id: c.id,
              type: c.type,
              start: c.start,
              end: c.end,
            ))
        .toList(growable: false);
    bool same = next.length == _authorConstraints.length;
    if (same) {
      for (var i = 0; i < next.length; i++) {
        final a = next[i];
        final b = _authorConstraints[i];
        if (a.id != b.id || a.type != b.type || a.start != b.start || a.end != b.end) {
          same = false;
          break;
        }
      }
    }
    if (same) return;
    _authorConstraints = next;
    notifyListeners();
  }

  bool get hasPlaybackHighlight =>
      _playbackStart >= 0 && _playbackEnd > _playbackStart;

  void setPlaybackRange(int start, int end) {
    if (_playbackStart == start && _playbackEnd == end) return;
    _playbackStart = start;
    _playbackEnd = end;
    notifyListeners();
  }

  void clearPlaybackRange() => setPlaybackRange(-1, -1);

  String get searchQuery => _searchQuery;
  set searchQuery(String value) {
    if (_searchQuery == value) return;
    _searchQuery = value;
    notifyListeners();
  }

  int get activeMatchOffset => _activeMatchOffset;
  set activeMatchOffset(int value) {
    if (_activeMatchOffset == value) return;
    _activeMatchOffset = value;
    notifyListeners();
  }

  void clearSearch() {
    if (_searchQuery.isEmpty && _activeMatchOffset == -1) return;
    _searchQuery = '';
    _activeMatchOffset = -1;
    notifyListeners();
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final String source = text;
    if (source.isEmpty) return TextSpan(style: style, text: source);

    final List<_BaseRange> base = _markdownRanges(source);
    final List<_OverlayRange> overlays = <_OverlayRange>[
      for (final c in _authorConstraints)
        if (c.start < c.end && c.start < source.length && c.end > 0)
          _OverlayRange(
            c.start.clamp(0, source.length),
            c.end.clamp(0, source.length),
            c.type == AuthorConstraintType.exact
                ? _OverlayKind.exactProtection
                : _OverlayKind.meaningProtection,
          ),
      ..._searchRanges(source),
      if (hasPlaybackHighlight)
        _OverlayRange(
          _playbackStart.clamp(0, source.length),
          _playbackEnd.clamp(0, source.length),
          _OverlayKind.playback,
        ),
    ];

    if (overlays.isEmpty) {
      return TextSpan(
        style: style,
        children: base.map((r) => _spanForBase(source, r, style)).toList(),
      );
    }

    final List<TextSpan> spans = <TextSpan>[];
    for (final _BaseRange b in base) {
      if (b.start >= b.end) continue;
      final Set<int> cuts = <int>{b.start, b.end};
      for (final _OverlayRange o in overlays) {
        if (o.end <= b.start || o.start >= b.end) continue;
        cuts.add(o.start.clamp(b.start, b.end));
        cuts.add(o.end.clamp(b.start, b.end));
      }
      final List<int> sorted = cuts.toList()..sort();
      for (int i = 0; i < sorted.length - 1; i++) {
        final int a = sorted[i];
        final int z = sorted[i + 1];
        if (a >= z) continue;
        final _OverlayRange? overlay = _overlayAt(overlays, a, z);
        spans.add(_spanForSegment(source, b, a, z, style, overlay));
      }
    }

    return TextSpan(style: style, children: spans);
  }

  List<_BaseRange> _markdownRanges(String source) {
    final List<_BaseRange> out = <_BaseRange>[];
    final RegExp regex = RegExp(r'(\*\*(.*?)\*\*)|(\*(.*?)\*)');
    int cursor = 0;

    for (final RegExpMatch match in regex.allMatches(source)) {
      if (match.start > cursor) {
        out.add(_BaseRange(cursor, match.start, _MarkdownKind.normal));
      }
      final String full = match.group(0)!;
      if (full.startsWith('**')) {
        out.add(_BaseRange(match.start, match.start + 2, _MarkdownKind.hidden));
        out.add(_BaseRange(match.start + 2, match.end - 2, _MarkdownKind.bold));
        out.add(_BaseRange(match.end - 2, match.end, _MarkdownKind.hidden));
      } else {
        out.add(_BaseRange(match.start, match.start + 1, _MarkdownKind.hidden));
        out.add(_BaseRange(match.start + 1, match.end - 1, _MarkdownKind.italic));
        out.add(_BaseRange(match.end - 1, match.end, _MarkdownKind.hidden));
      }
      cursor = match.end;
    }

    if (cursor < source.length) {
      out.add(_BaseRange(cursor, source.length, _MarkdownKind.normal));
    }
    if (out.isEmpty) {
      out.add(_BaseRange(0, source.length, _MarkdownKind.normal));
    }
    return out;
  }

  List<_OverlayRange> _searchRanges(String source) {
    if (_searchQuery.length < _minSearchLength) return const <_OverlayRange>[];
    final String haystack = source.toLowerCase();
    final String needle = _searchQuery.toLowerCase();
    final List<_OverlayRange> out = <_OverlayRange>[];
    int index = haystack.indexOf(needle);
    int count = 0;
    while (index >= 0 && count < 1500) {
      out.add(_OverlayRange(
        index,
        index + needle.length,
        index == _activeMatchOffset
            ? _OverlayKind.activeSearch
            : _OverlayKind.search,
      ));
      index = haystack.indexOf(needle, index + needle.length);
      count++;
    }
    return out;
  }

  _OverlayRange? _overlayAt(List<_OverlayRange> overlays, int a, int z) {
    _OverlayRange? best;
    int bestPriority = -1;
    for (final _OverlayRange o in overlays) {
      if (a < o.start || z > o.end) continue;
      final priority = switch (o.kind) {
        _OverlayKind.playback => 4,
        _OverlayKind.activeSearch => 3,
        _OverlayKind.search => 2,
        _OverlayKind.exactProtection || _OverlayKind.meaningProtection => 1,
      };
      if (priority > bestPriority) {
        best = o;
        bestPriority = priority;
      }
    }
    return best;
  }

  TextSpan _spanForBase(String source, _BaseRange range, TextStyle? style) =>
      _spanForSegment(source, range, range.start, range.end, style, null);

  TextSpan _spanForSegment(
    String source,
    _BaseRange base,
    int start,
    int end,
    TextStyle? style,
    _OverlayRange? overlay,
  ) {
    TextStyle? resolved = style;
    switch (base.kind) {
      case _MarkdownKind.hidden:
        resolved = resolved?.copyWith(color: Colors.transparent, fontSize: 0.1);
        break;
      case _MarkdownKind.bold:
        resolved = resolved?.copyWith(fontWeight: FontWeight.bold, color: Colors.white);
        break;
      case _MarkdownKind.italic:
        resolved = resolved?.copyWith(fontStyle: FontStyle.italic);
        break;
      case _MarkdownKind.normal:
        break;
    }

    // Do not paint the zero-size markdown markers themselves.
    if (base.kind != _MarkdownKind.hidden && overlay != null) {
      switch (overlay.kind) {
        case _OverlayKind.playback:
          resolved = resolved?.copyWith(
            backgroundColor: const Color(0xFF29434A),
            color: const Color(0xFF80DEEA),
          );
          break;
        case _OverlayKind.activeSearch:
          resolved = resolved?.copyWith(
            backgroundColor: const Color(0xFFFFC107),
            color: Colors.black,
            fontWeight: FontWeight.w600,
          );
          break;
        case _OverlayKind.search:
          resolved = resolved?.copyWith(
            backgroundColor: const Color(0x665A6B73),
          );
          break;
        case _OverlayKind.exactProtection:
          resolved = resolved?.copyWith(
            backgroundColor: const Color(0x334D8A8A),
            decoration: TextDecoration.underline,
            decorationColor: const Color(0xFF80CBC4),
            decorationThickness: 1.5,
          );
          break;
        case _OverlayKind.meaningProtection:
          resolved = resolved?.copyWith(
            backgroundColor: const Color(0x333F2B63),
            decoration: TextDecoration.underline,
            decorationColor: const Color(0xFFB39DDB),
            decorationStyle: TextDecorationStyle.dotted,
            decorationThickness: 1.5,
          );
          break;
      }
    }

    return TextSpan(text: source.substring(start, end), style: resolved);
  }
}

enum _MarkdownKind { normal, hidden, bold, italic }
enum _OverlayKind {
  playback,
  search,
  activeSearch,
  exactProtection,
  meaningProtection,
}

class _BaseRange {
  final int start;
  final int end;
  final _MarkdownKind kind;
  const _BaseRange(this.start, this.end, this.kind);
}

class _OverlayRange {
  final int start;
  final int end;
  final _OverlayKind kind;
  const _OverlayRange(this.start, this.end, this.kind);
}
