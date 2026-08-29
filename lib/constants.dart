import 'package:flutter/material.dart';

const double kWorldSize = 50000.0;
const double kNodeWidth = 220.0;
const double kNodeHeight = 120.0;
const Color kCanvasBg = Color(0xFF111111);
const Color kNodeBg = Color(0xFF252525);
const Color kAccentColor = Colors.orangeAccent;

enum NodeType { scene, output, merge, ollama }