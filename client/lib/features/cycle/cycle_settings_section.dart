import 'package:flutter/material.dart';

import '../../application/cycle_controller.dart';

class CycleSettingsSection extends StatelessWidget {
  const CycleSettingsSection({
    super.key,
    required this.controller,
    required this.onOpenSummary,
  });

  final CycleController controller;
  final VoidCallback onOpenSummary;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('健康与隐私', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.water_drop_outlined),
          title: const Text('经期跟踪'),
          subtitle: const Text('记录仅保存在本机，不进入同步、ICS 或普通 JSON'),
          value: controller.enabled,
          onChanged: controller.mutating
              ? null
              : (value) async {
                  try {
                    await controller.setEnabled(value);
                  } catch (error) {
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(SnackBar(content: Text('保存经期设置失败：$error')));
                  }
                },
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          enabled: controller.enabled,
          leading: const Icon(Icons.monitor_heart_outlined),
          title: const Text('周期概览与记录'),
          subtitle: Text(
            controller.periods.isEmpty
                ? '尚无记录'
                : '已记录 ${controller.periods.length} 次经期',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: controller.enabled ? onOpenSummary : null,
        ),
        if (controller.error != null)
          Text(
            '经期数据加载失败：${controller.error}',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
      ],
    ),
  );
}
