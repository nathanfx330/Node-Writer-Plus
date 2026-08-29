enum AuthorConstraintType { exact, meaning }

class AuthorConstraint {
  AuthorConstraint({
    required this.id,
    required this.type,
    required this.start,
    required this.end,
  });

  final String id;
  AuthorConstraintType type;
  int start;
  int end;

  bool overlaps(int a, int z) => start < z && end > a;

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.name,
        'start': start,
        'end': end,
      };

  factory AuthorConstraint.fromJson(Map<String, dynamic> json) {
    final start = (json['start'] as num?)?.toInt() ?? 0;
    final end = (json['end'] as num?)?.toInt() ?? 0;
    final rawId = json['id']?.toString() ?? '';
    return AuthorConstraint(
      // A blank id would collide with every other blank id when the harness
      // mints exact-lock tokens, so fall back to something span-unique.
      id: rawId.isNotEmpty ? rawId : 'legacy-$start-$end',
      type: json['type'] == 'meaning'
          ? AuthorConstraintType.meaning
          : AuthorConstraintType.exact,
      start: start,
      end: end,
    );
  }
}
