import 'package:flutter/material.dart';

class MarkdownSyntaxController extends TextEditingController {
  @override
  TextSpan buildTextSpan(
      {required BuildContext context,
      TextStyle? style,
      required bool withComposing}) {
    final children = <TextSpan>[];
    final regex = RegExp(r'(\*\*(.*?)\*\*)|(\*(.*?)\*)');
    final text = this.text;
    int currentIndex = 0;

    for (final match in regex.allMatches(text)) {
      if (match.start > currentIndex) {
        children.add(TextSpan(text: text.substring(currentIndex, match.start), style: style));
      }
      final fullMatch = match.group(0)!;
      final hiddenStyle = style?.copyWith(color: Colors.transparent, fontSize: 0.1);
      
      if (fullMatch.startsWith('**')) {
        children.add(TextSpan(text: '**', style: hiddenStyle));
        children.add(TextSpan(text: match.group(2), style: style?.copyWith(fontWeight: FontWeight.bold, color: Colors.white)));
        children.add(TextSpan(text: '**', style: hiddenStyle));
      } else {
        children.add(TextSpan(text: '*', style: hiddenStyle));
        children.add(TextSpan(text: match.group(4), style: style?.copyWith(fontStyle: FontStyle.italic)));
        children.add(TextSpan(text: '*', style: hiddenStyle));
      }
      currentIndex = match.end;
    }
    if (currentIndex < text.length) {
      children.add(TextSpan(text: text.substring(currentIndex), style: style));
    }
    return TextSpan(style: style, children: children);
  }
}