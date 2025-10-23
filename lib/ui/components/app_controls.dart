// lib/ui/components/app_controls.dart

import 'package:flutter/material.dart';

/// ===============================================
/// 🎨 AppControls — 공통 디자인 세트
/// ===============================================

class AppSection extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;

  const AppSection({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(10),
    this.margin = const EdgeInsets.symmetric(vertical: 3),
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: margin,
      padding: padding,
      clipBehavior: Clip.antiAlias, // ✅ 라운드 밖 잔물결 방지
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer.withOpacity(0.22),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withOpacity(0.35),
        ),
      ),
      child: child,
    );
  }
}

/// ✅ 공통 소형 버튼 (앱형 디자인)
class AppMiniButton extends StatelessWidget {
  final IconData icon;
  final String? label; // <- nullable 로
  final VoidCallback onPressed;
  final bool compact;
  final bool iconOnly; // <- 추가
  final double iconSize; // <- 추가
  final double? fontSize; // <- 추가
  final Size minSize; // <- 추가

  const AppMiniButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.label, // <- 변경
    this.compact = false,
    this.iconOnly = false,
    this.iconSize = 20,
    this.fontSize,
    this.minSize = const Size(34, 32),
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final baseText = theme.textTheme.labelLarge?.copyWith(
      fontSize: fontSize ?? (compact ? 12 : 14),
      fontWeight: FontWeight.w600,
    );

    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
    );
    final style = FilledButton.styleFrom(
      padding: iconOnly
          ? EdgeInsets.zero
          : (compact
                ? const EdgeInsets.symmetric(horizontal: 8, vertical: 6)
                : const EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
      minimumSize: minSize,
      shape: shape,
      backgroundColor: theme.colorScheme.secondaryContainer,
      foregroundColor: theme.colorScheme.onSecondaryContainer,
    );

    if (iconOnly) {
      return FilledButton(
        onPressed: onPressed,
        style: style,
        child: Icon(icon, size: iconSize),
      );
    }

    return FilledButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: iconSize),
      label: Text(label ?? '', style: baseText),
      style: style,
    );
  }
}


/// ✅ 프리셋(50~100%) 박스형 버튼 — 플랫 & 감성톤
class PresetSquare extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;

  // ✅ 기본 사이즈 더 아담하게 (2줄구성 유지에 도움)
  final double size; // width
  final double height; // height
  final double fontSize;

  const PresetSquare({
    super.key,
    required this.label,
    required this.active,
    required this.onTap,
    this.size = 32, // 🔽 38 → 32
    this.height = 22, // 🔽 30 → 22
    this.fontSize = 10, // 🔽 12 → 10
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final skyFill = theme.colorScheme.primary.withOpacity(0.10);
    final skyStroke = theme.colorScheme.primary.withOpacity(0.50);
    final baseFill = theme.colorScheme.surfaceVariant.withOpacity(0.55);
    final baseStroke = theme.colorScheme.outlineVariant.withOpacity(0.35);
    final textColor = active
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurface.withOpacity(0.78);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          width: size,
          height: height,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? skyFill : baseFill, // ✅ 플랫
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: active ? skyStroke : baseStroke),
          ),
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: fontSize,
              fontWeight: FontWeight.w700,
              color: textColor,
              letterSpacing: 0.2,
            ),
          ),
        ),
      ),
    );
  }
}
