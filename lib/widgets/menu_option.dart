import 'package:flutter/material.dart';

class MenuOption {
  final String title;
  final IconData icon;
  final Color color;

  /// Builder that creates the page widget on demand.
  /// This avoids instantiating all 8 feature screens at HomeScreen startup.
  final WidgetBuilder pageBuilder;

  const MenuOption(this.title, this.icon, this.color, this.pageBuilder);
}
