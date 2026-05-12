import 'dart:ui';
import '../constants.dart';

class StoryNode {
  final String id;
  final NodeType type;
  String title;
  String content;
  Offset position;
  List<String> nextNodeIds;
  TextAlign textAlign;
  String fontFamily;

  StoryNode({
    required this.id, required this.position, this.type = NodeType.scene,
    this.title = "Untitled", this.content = "", this.textAlign = TextAlign.left,
    this.fontFamily = "Modern", List<String>? nextNodeIds,
  }) : nextNodeIds = nextNodeIds ?? [];

  double get currentHeight => type == NodeType.scene ? kNodeHeight : 60.0;
  
  Offset get inputPortLocal => Offset(kNodeWidth / 2, 0);
  Offset get outputPortLocal => Offset(kNodeWidth / 2, currentHeight);
  Offset get inputPortGlobal => position + inputPortLocal;
  Offset get outputPortGlobal => position + outputPortLocal;
  Rect get rect => position & Size(kNodeWidth, currentHeight);

  Map<String, dynamic> toJson() => {
    'id': id, 'type': type.toString(), 'title': title, 'content': content,
    'align': textAlign.toString(), 'font': fontFamily,
    'dx': position.dx, 'dy': position.dy, 'next_ids': nextNodeIds,
  };

  factory StoryNode.fromJson(Map<String, dynamic> json) {
    NodeType parsedType = NodeType.scene;
    if (json['type'] == 'NodeType.output') parsedType = NodeType.output;
    if (json['type'] == 'NodeType.merge') parsedType = NodeType.merge;

    return StoryNode(
      id: json['id'],
      type: parsedType,
      title: json['title'], content: json['content'],
      textAlign: stringToTextAlign(json['align']),
      fontFamily: json['font'] ?? "Modern", position: Offset(json['dx'], json['dy']),
      nextNodeIds: List<String>.from(json['next_ids'] ?? (json['next'] != null ? [json['next']] : [])),
    );
  }

  static TextAlign stringToTextAlign(String? str) {
    if (str == 'TextAlign.center') return TextAlign.center;
    if (str == 'TextAlign.right') return TextAlign.right;
    if (str == 'TextAlign.justify') return TextAlign.justify;
    return TextAlign.left;
  }
}