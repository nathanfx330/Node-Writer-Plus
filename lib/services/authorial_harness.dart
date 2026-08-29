import 'dart:convert';

import '../models/authorial_constraint.dart';
import '../models/compiled_manuscript.dart';
import 'ollama_service.dart';

class ExactTokenBinding {
  const ExactTokenBinding({
    required this.token,
    required this.constraint,
  });

  final String token;
  final CompiledConstraint constraint;
}

class HarnessedManuscript {
  const HarnessedManuscript({
    required this.text,
    required this.systemRules,
    required this.exactTokens,
    required this.meaningConstraints,
  });

  final String text;
  final String systemRules;
  final List<ExactTokenBinding> exactTokens;
  final List<CompiledConstraint> meaningConstraints;

  String restoreExactTokens(String output) {
    var restored = output;
    for (final binding in exactTokens) {
      restored = restored.replaceAll(binding.token, binding.constraint.text);
    }
    return restored;
  }

  List<String> validateExactTokens(
    String output, {
    bool requireEveryToken = false,
  }) {
    final issues = <String>[];
    for (final binding in exactTokens) {
      final count = binding.token.allMatches(output).length;
      if (requireEveryToken && count == 0) {
        issues.add(
          '${binding.constraint.nodeTitle}, lines ${_lineLabel(binding.constraint)}: protected wording was omitted.',
        );
      } else if (count > 1) {
        issues.add(
          '${binding.constraint.nodeTitle}, lines ${_lineLabel(binding.constraint)}: protected wording was duplicated.',
        );
      }
    }
    if (output.contains('[[NW_EXACT_')) {
      final known = exactTokens.map((e) => e.token).toSet();
      final marker = RegExp(r'\[\[NW_EXACT_[A-Za-z0-9_-]+\]\]');
      for (final match in marker.allMatches(output)) {
        final token = match.group(0)!;
        if (!known.contains(token)) {
          issues.add('Ollama returned an unknown or altered protected token: $token');
        }
      }
    }
    return issues;
  }

  static String _lineLabel(CompiledConstraint c) =>
      c.lineStart == c.lineEnd ? '${c.lineStart}' : '${c.lineStart}-${c.lineEnd}';
}

class MeaningCheck {
  const MeaningCheck({
    required this.id,
    required this.status,
    required this.reason,
  });

  final String id;
  final String status;
  final String reason;
}

class AuthorialHarness {
  static HarnessedManuscript prepare(CompiledManuscript manuscript) {
    var protectedText = manuscript.text;
    final exact = manuscript.exactConstraints.toList()
      ..sort((a, b) => b.start.compareTo(a.start));
    final bindings = <ExactTokenBinding>[];

    for (final constraint in exact) {
      final safeId = constraint.id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
      final token = '[[NW_EXACT_${safeId.isEmpty ? bindings.length + 1 : safeId}]]';
      if (constraint.start < 0 ||
          constraint.end > protectedText.length ||
          constraint.start >= constraint.end) {
        continue;
      }
      protectedText = protectedText.replaceRange(
        constraint.start,
        constraint.end,
        token,
      );
      bindings.add(ExactTokenBinding(token: token, constraint: constraint));
    }

    bindings.sort((a, b) =>
        a.constraint.start.compareTo(b.constraint.start));

    final rules = StringBuffer()
      ..writeln('NODE WRITER AUTHORIAL CONSTRAINT HARNESS')
      ..writeln('The manuscript contains author-owned text that has explicit editing constraints.')
      ..writeln('These constraints override stylistic preferences and ordinary rewrite instructions.')
      ..writeln()
      ..writeln('EXACT LOCKS')
      ..writeln('- Tokens shaped like [[NW_EXACT_...]] stand for exact author wording.')
      ..writeln('- Never edit, split, rename, paraphrase, or invent one of these tokens.')
      ..writeln('- If your answer reproduces or rewrites manuscript text containing a token, copy that token exactly where the protected wording belongs.')
      ..writeln('- If your answer is analysis/commentary and does not reproduce that passage, the token does not need to appear.')
      ..writeln('- You may discuss protected wording, but do not silently substitute alternate wording for it.')
      ..writeln()
      ..writeln('MEANING / CLAIM LOCKS')
      ..writeln('- A meaning lock protects the author’s proposition, emphasis, and intended point.')
      ..writeln('- You may improve surrounding prose when the task calls for editing, but do not reverse, weaken, strengthen, qualify, or reinterpret a locked claim.')
      ..writeln('- You may criticize or question a locked claim when the user asks for analysis, but keep criticism separate from the author’s wording.')
      ..writeln('- If a requested rewrite conflicts with a locked claim, preserve the claim and work around it.');

    if (bindings.isNotEmpty) {
      rules
        ..writeln()
        ..writeln('EXACT LOCK REFERENCE (for comprehension only):');
      for (final binding in bindings) {
        final c = binding.constraint;
        rules.writeln(
          '${binding.token} = ${jsonEncode(c.text)}  [${c.nodeTitle}, lines ${_lineLabel(c)}]',
        );
      }
    }

    final meaning = manuscript.meaningConstraints;
    if (meaning.isNotEmpty) {
      rules
        ..writeln()
        ..writeln('LOCKED CLAIMS:');
      for (final c in meaning) {
        rules.writeln(
          '${c.id} [${c.nodeTitle}, lines ${_lineLabel(c)}]: ${jsonEncode(c.text)}',
        );
      }
    }

    return HarnessedManuscript(
      text: protectedText,
      systemRules: rules.toString().trim(),
      exactTokens: bindings,
      meaningConstraints: meaning,
    );
  }

  static Future<List<MeaningCheck>> verifyMeaningLocks({
    required OllamaService service,
    required String model,
    required List<CompiledConstraint> constraints,
    required String generatedDocument,
  }) async {
    if (constraints.isEmpty) return const <MeaningCheck>[];

    final claims = constraints.map((c) {
      return {
        'id': c.id,
        'scene': c.nodeTitle,
        'lines': _lineLabel(c),
        'claim': c.text,
      };
    }).toList();

    final prompt = '''
You are validating whether an edited document preserved specific authorial claims.
Do not edit or rewrite anything. Compare each protected claim against the generated document.
A claim is PRESERVED only when its proposition, emphasis, scope, certainty, and direction remain materially the same.
Use CHANGED when the generated document changes the claim. Use UNCERTAIN when you cannot determine preservation reliably.

Protected claims:
${jsonEncode(claims)}

Generated document:
$generatedDocument

Return JSON exactly in this shape:
{"checks":[{"id":"constraint-id","status":"PRESERVED|CHANGED|UNCERTAIN","reason":"one short sentence"}]}
''';

    try {
      final raw = await service.generate(
        model: model,
        prompt: prompt,
        system: 'You are a strict semantic preservation checker. Return JSON only.',
        jsonFormat: true,
      );
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic> || decoded['checks'] is! List) {
        throw const FormatException('Missing checks array');
      }
      final byId = <String, MeaningCheck>{};
      for (final item in decoded['checks'] as List) {
        if (item is! Map) continue;
        final id = item['id']?.toString() ?? '';
        final status = item['status']?.toString().toUpperCase() ?? 'UNCERTAIN';
        final reason = item['reason']?.toString() ?? '';
        if (id.isEmpty) continue;
        byId[id] = MeaningCheck(
          id: id,
          status: const {'PRESERVED', 'CHANGED', 'UNCERTAIN'}.contains(status)
              ? status
              : 'UNCERTAIN',
          reason: reason,
        );
      }
      return constraints
          .map((c) => byId[c.id] ?? MeaningCheck(
                id: c.id,
                status: 'UNCERTAIN',
                reason: 'The verifier did not return a result for this claim.',
              ))
          .toList(growable: false);
    } catch (_) {
      return constraints
          .map((c) => MeaningCheck(
                id: c.id,
                status: 'UNCERTAIN',
                reason: 'Meaning verification could not be completed.',
              ))
          .toList(growable: false);
    }
  }

  static String _lineLabel(CompiledConstraint c) =>
      c.lineStart == c.lineEnd ? '${c.lineStart}' : '${c.lineStart}-${c.lineEnd}';
}
