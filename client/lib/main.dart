import 'package:flutter/widgets.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import 'app.dart';
import 'application/item_controller.dart';
import 'config/app_config.dart';
import 'data/local_item_repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final config = AppConfig.fromEnvironment();
  tz_data.initializeTimeZones();
  tz.setLocalLocation(tz.getLocation(config.timezone));
  await initializeDateFormatting('zh_CN');
  final controller = ItemController(
    repository: LocalItemRepository(config),
    config: config,
  );
  await controller.initialize();
  runApp(EasyCalendarApp(config: config, controller: controller));
}
