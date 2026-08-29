import 'authorial_constraint.dart';

class CompiledConstraint {
  const CompiledConstraint({
    required this.id,
    required this.nodeId,
    required this.nodeTitle,
    required this.type,
    required this.start,
    required this.end,
    required this.text,
    required this.lineStart,
    required this.lineEnd,
  });

  final String id;
  final String nodeId;
  final String nodeTitle;
  final AuthorConstraintType type;
  final int start;
  final int end;
  final String text;
  final int lineStart;
  final int lineEnd;
}

class CompiledManuscript {
  const CompiledManuscript({
    required this.text,
    required this.constraints,
  });

  final String text;
  final List<CompiledConstraint> constraints;

  List<CompiledConstraint> get exactConstraints => constraints
      .where((c) => c.type == AuthorConstraintType.exact)
      .toList(growable: false);

  List<CompiledConstraint> get meaningConstraints => constraints
      .where((c) => c.type == AuthorConstraintType.meaning)
      .toList(growable: false);
}
