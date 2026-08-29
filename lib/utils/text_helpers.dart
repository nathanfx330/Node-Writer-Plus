// utils/text_helpers.dart

/// One playback unit: a sentence, or a run of blank lines.
///
/// [start] and [end] are absolute character offsets into the source document.
/// The concatenation of every chunk's [text] is byte for byte identical to the
/// original document, which is what lets the editor map highlights and scroll
/// targets back onto the real text without an index translation table.
class TextChunk {
  final String text;
  final int start;
  final int end;
  final bool hasSpeech;
  final bool startsParagraph;

  const TextChunk({
    required this.text,
    required this.start,
    required this.end,
    required this.hasSpeech,
    required this.startsParagraph,
  });

  int get length => end - start;

  /// Display form: trimmed and whitespace collapsed, for the navigator list.
  String get label => text.trim().replaceAll(RegExp(r'\s+'), ' ');
}

class TextHelpers {
  TextHelpers._();

  /// Abbreviations that must not terminate a sentence.
  static const String _abbreviations =
      r'Mr|Mrs|Ms|Dr|Prof|Sr|Jr|St|vs|Inc|Corp|Ltd|Fig|No|Vol|Ch|pp|Rev|Gen|'
      r'Sen|Rep|Col|Lt|Capt|Sgt|Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sept|Sep|Oct|Nov|Dec';

  /// Sentence splitter.
  ///
  /// Three alternatives, tried in order at each position:
  ///   1. text up to a terminator that is not part of an abbreviation,
  ///      not preceded by a lone letter (kills "U.S.", "e.g.", "i.e."),
  ///      and not followed by a digit (kills "4.5", "3.2.1", "v1.2")
  ///   2. text up to and including a run of newlines
  ///   3. whatever is left
  ///
  /// The lone-letter guard is the important one. The previous form only
  /// protected the final period of a multi-period abbreviation, so "the U.S."
  /// split after "U." and "Cost 4.5 million" split after "4.".
  static final RegExp _sentenceRegex = RegExp(
    r'.*?(?<!\b(?:' +
        _abbreviations +
        r'))(?<!\b\p{L})[.!?]+(?!\d)|.*?\n+|.+',
    caseSensitive: false,
    unicode: true,
  );

  static final RegExp _speechTest = RegExp(r'[\p{L}\p{N}]', unicode: true);

  /// Emoji, pictographs, dingbats, flags, variation selectors and ZWJ.
  /// Deliberately expressed as code point ranges rather than \p{So} so that
  /// currency, math and comparison symbols ($ + = < > ~ ^ |) survive.
  static final RegExp _pictographs = RegExp(
    r'[\u{1F000}-\u{1FAFF}\u{1F1E6}-\u{1F1FF}\u{2190}-\u{21FF}'
    r'\u{2300}-\u{23FF}\u{2460}-\u{24FF}\u{2600}-\u{27BF}'
    r'\u{2B00}-\u{2BFF}\u{FE00}-\u{FE0F}\u{200D}\u{FE0E}]',
    unicode: true,
  );

  /// Splits a document into chunks with absolute offsets preserved.
  static List<TextChunk> splitIntoChunks(String text) {
    if (text.isEmpty) return const <TextChunk>[];

    final List<TextChunk> out = <TextChunk>[];
    bool paragraphPending = true;

    for (final Match m in _sentenceRegex.allMatches(text)) {
      final String slice = m.group(0)!;
      if (slice.isEmpty) continue;

      final bool speech = _speechTest.hasMatch(slice);
      out.add(TextChunk(
        text: slice,
        start: m.start,
        end: m.end,
        hasSpeech: speech,
        startsParagraph: paragraphPending && speech,
      ));

      if (speech) {
        paragraphPending = slice.endsWith('\n');
      } else {
        paragraphPending = true;
      }
    }
    return out;
  }

  /// Convenience wrapper for callers that only want the raw strings.
  static List<String> splitIntoSentences(String text) =>
      splitIntoChunks(text).map((TextChunk c) => c.text).toList();

  /// Binary search: which chunk contains this character offset.
  static int chunkIndexForOffset(List<TextChunk> chunks, int offset) {
    if (chunks.isEmpty) return 0;
    if (offset <= 0) return 0;
    int lo = 0;
    int hi = chunks.length - 1;
    while (lo < hi) {
      final int mid = (lo + hi + 1) >> 1;
      if (chunks[mid].start <= offset) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  /// The next chunk at or after [index] that actually contains speech.
  static int nextSpeakableIndex(List<TextChunk> chunks, int index) {
    for (int i = index.clamp(0, chunks.length); i < chunks.length; i++) {
      if (chunks[i].hasSpeech) return i;
    }
    return index.clamp(0, chunks.isEmpty ? 0 : chunks.length - 1);
  }

  static int wordCount(String text) {
    if (text.trim().isEmpty) return 0;
    return RegExp(r'[\p{L}\p{N}\u2019' r"']+", unicode: true)
        .allMatches(text)
        .length;
  }

  /// Strips markdown emphasis, heading markers and assistant preamble.
  static String quickClean(String text, {required bool stripSpecialChars}) {
    String out = text;

    if (stripSpecialChars) {
      out = out.replaceAll(_pictographs, '');
    }

    out = out.replaceAll(RegExp(r'\*\*|\*|__|_'), '');
    out = out.replaceAll(RegExp(r'^\s{0,3}#{1,6}\s*', multiLine: true), '');
    out = out.replaceAll(RegExp(r'^\s*>\s?', multiLine: true), '');
    out = out.replaceAll(RegExp(r'`{1,3}'), '');
    out = out.replaceAll(
      RegExp(r'^\s*(Sure|Certainly|Of course|Absolutely)[!,]?\s*.*?:\s*',
          multiLine: true, caseSensitive: false),
      '',
    );

    // Collapse runs of three or more newlines down to a paragraph break.
    out = out.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return out;
  }

  /// Rejoins hard-wrapped text back into paragraphs. Fixes PDF copy-paste.
  static String fixBrokenLines(
    String text, {
    required double minLineLength,
    required bool smartJoinLabels,
  }) {
    final List<String> lines = text.split('\n');
    final List<String> result = <String>[];
    final int minLen = minLineLength.toInt();
    String paragraph = '';

    for (final String raw in lines) {
      final String line = raw.trimRight();

      if (line.trim().isEmpty) {
        if (paragraph.isNotEmpty) {
          result.add(paragraph);
          paragraph = '';
        }
        result.add('');
        continue;
      }

      if (paragraph.isEmpty) {
        paragraph = line.trimLeft();
      } else {
        paragraph += ' ${line.trimLeft()}';
      }

      bool joinToNext = line.length >= minLen;
      if (!joinToNext && smartJoinLabels) {
        joinToNext = line.length <= 3 || line.endsWith(':');
      }

      if (!joinToNext) {
        result.add(paragraph);
        paragraph = '';
      }
    }

    if (paragraph.isNotEmpty) result.add(paragraph);

    return result.join('\n').replaceAll(RegExp(r'[ \t]{2,}'), ' ');
  }
}
