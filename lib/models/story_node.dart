import 'dart:ui';
import '../constants.dart';
import 'authorial_constraint.dart';

class StoryNode {
  final String id;
  final NodeType type;
  String title;
  String content;
  Offset position;
  List<String> nextNodeIds;
  TextAlign textAlign;
  String fontFamily;

  // Ollama output nodes keep only the node-specific ask/result. Host/model/system
  // behavior is application-wide and lives in Settings → Ollama.
  String ollamaPrompt;
  List<AuthorConstraint> authorConstraints;

  StoryNode({
    required this.id,
    required this.position,
    this.type = NodeType.scene,
    this.title = "Untitled",
    this.content = "",
    this.textAlign = TextAlign.left,
    this.fontFamily = "Modern",
    List<String>? nextNodeIds,
    this.ollamaPrompt = '',
    List<AuthorConstraint>? authorConstraints,
  })  : nextNodeIds = nextNodeIds ?? [],
        authorConstraints = authorConstraints ?? <AuthorConstraint>[];

  // Scene is the only writing-card node. Output, Merge, and Ollama are
  // compact graph operators/sinks.
  double get currentHeight => type == NodeType.scene ? kNodeHeight : 60.0;

  Offset get inputPortLocal => Offset(kNodeWidth / 2, 0);
  Offset get outputPortLocal => Offset(kNodeWidth / 2, currentHeight);
  Offset get inputPortGlobal => position + inputPortLocal;
  Offset get outputPortGlobal => position + outputPortLocal;
  Rect get rect => position & Size(kNodeWidth, currentHeight);

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.toString(),
        'title': title,
        'content': content,
        'align': textAlign.toString(),
        'font': fontFamily,
        'dx': position.dx,
        'dy': position.dy,
        'next_ids': nextNodeIds,
        if (type == NodeType.ollama) 'ollama_prompt': ollamaPrompt,
        if (type == NodeType.scene)
          'author_constraints': authorConstraints.map((c) => c.toJson()).toList(),
      };

  /// Tolerant of missing and mistyped fields.
  ///
  /// A project file is the author's manuscript. One unexpected key should
  /// degrade a single node, never abort the load, so every field falls back to
  /// a usable default and only a missing id is fatal.
  factory StoryNode.fromJson(Map<String, dynamic> json) {
    NodeType parsedType = NodeType.scene;
    final rawType = json['type']?.toString();
    if (rawType == 'NodeType.output') parsedType = NodeType.output;
    if (rawType == 'NodeType.merge') parsedType = NodeType.merge;
    if (rawType == 'NodeType.ollama') parsedType = NodeType.ollama;

    final id = json['id']?.toString();
    if (id == null || id.isEmpty) {
      throw const FormatException('Node is missing an id.');
    }

    final rawNext = json['next_ids'];
    final List<String> nextIds;
    if (rawNext is List) {
      nextIds = rawNext.map((e) => e.toString()).toList();
    } else if (json['next'] != null) {
      nextIds = <String>[json['next'].toString()];
    } else {
      nextIds = <String>[];
    }

    return StoryNode(
      id: id,
      type: parsedType,
      title: json['title']?.toString() ?? 'Untitled',
      content: json['content']?.toString() ?? '',
      textAlign: stringToTextAlign(json['align']?.toString()),
      fontFamily: json['font']?.toString() ?? "Modern",
      position: Offset(
        (json['dx'] as num?)?.toDouble() ?? kWorldSize / 2,
        (json['dy'] as num?)?.toDouble() ?? kWorldSize / 2,
      ),
      nextNodeIds: parsedType == NodeType.ollama ? <String>[] : nextIds,
      ollamaPrompt: json['ollama_prompt']?.toString() ?? '',
      authorConstraints: (json['author_constraints'] is List
              ? json['author_constraints'] as List
              : const <dynamic>[])
          .whereType<Map>()
          .map((c) => AuthorConstraint.fromJson(Map<String, dynamic>.from(c)))
          .where((c) => c.end > c.start)
          .toList(),
    );
  }

  static TextAlign stringToTextAlign(String? str) {
    if (str == 'TextAlign.center') return TextAlign.center;
    if (str == 'TextAlign.right') return TextAlign.right;
    if (str == 'TextAlign.justify') return TextAlign.justify;
    return TextAlign.left;
  }
}
