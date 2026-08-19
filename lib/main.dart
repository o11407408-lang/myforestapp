import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest_all.dart' as tzdata;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.init();
  runApp(const MyApp());
}

// ---------------------------------------------------------------------------
// Виды деревьев
// ---------------------------------------------------------------------------

class TreeSpecies {
  final String id;
  final String name;
  final IconData icon;
  final Color color;
  final int unlockAt; // сколько успешных деревьев нужно вырастить, 0 = открыт сразу

  const TreeSpecies({
    required this.id,
    required this.name,
    required this.icon,
    required this.color,
    required this.unlockAt,
  });
}

const List<TreeSpecies> treeSpecies = [
  TreeSpecies(
    id: 'oak',
    name: 'дуб',
    icon: Icons.park_rounded,
    color: Color(0xFF2E7D32),
    unlockAt: 0,
  ),
  TreeSpecies(
    id: 'pine',
    name: 'сосна',
    icon: Icons.forest_rounded,
    color: Color(0xFF1B5E20),
    unlockAt: 3,
  ),
  TreeSpecies(
    id: 'sakura',
    name: 'сакура',
    icon: Icons.local_florist_rounded,
    color: Color(0xFFEC407A),
    unlockAt: 7,
  ),
  TreeSpecies(
    id: 'palm',
    name: 'пальма',
    icon: Icons.beach_access_rounded,
    color: Color(0xFF00897B),
    unlockAt: 12,
  ),
  TreeSpecies(
    id: 'maple',
    name: 'клён',
    icon: Icons.eco_rounded,
    color: Color(0xFFE65100),
    unlockAt: 20,
  ),
  TreeSpecies(
    id: 'gold',
    name: 'золотое дерево',
    icon: Icons.auto_awesome_rounded,
    color: Color(0xFFFFB300),
    unlockAt: 30,
  ),
];

TreeSpecies speciesById(String id) {
  return treeSpecies.firstWhere(
    (s) => s.id == id,
    orElse: () => treeSpecies.first,
  );
}

// ---------------------------------------------------------------------------
// Модель данных сеанса
// ---------------------------------------------------------------------------

class FocusSession {
  final DateTime date;
  final int durationMinutes;
  final bool success;
  final String speciesId;

  FocusSession({
    required this.date,
    required this.durationMinutes,
    required this.success,
    required this.speciesId,
  });
}

// ---------------------------------------------------------------------------
// Сервис уведомлений
// ---------------------------------------------------------------------------

class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  static const _dailyChannelId = 'focus_tree_daily';
  static const _testChannelId = 'focus_tree_test';

  static Future<void> init() async {
    if (_initialized) return;
    try {
      tzdata.initializeTimeZones();

      // Определяем реальный IANA-часовой пояс устройства (например
      // "Europe/Moscow"), чтобы напоминание приходило именно в то локальное
      // время, которое выбрал пользователь, а не по UTC-приближению.
      try {
        final String currentTimeZone = await FlutterTimezone.getLocalTimezone();
        tz.setLocalLocation(tz.getLocation(currentTimeZone));
      } catch (e) {
        debugPrint('Не удалось определить часовой пояс устройства: $e');
      }

      const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
      const iosSettings = DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      );
      const settings = InitializationSettings(android: androidSettings, iOS: iosSettings);
      await _plugin.initialize(settings);

      final androidImpl = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await androidImpl?.requestNotificationsPermission();

      _initialized = true;
    } catch (e) {
      // Если что-то пошло не так (например, старое устройство или нет
      // прав) — приложение всё равно должно нормально запуститься.
      debugPrint('NotificationService init error: $e');
    }
  }

  static Future<bool> areNotificationsAllowed() async {
    try {
      final androidImpl = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      final enabled = await androidImpl?.areNotificationsEnabled();
      return enabled ?? true;
    } catch (_) {
      return true;
    }
  }

  static Future<void> showTestNotification() async {
    const androidDetails = AndroidNotificationDetails(
      _testChannelId,
      'Тестовые уведомления',
      channelDescription: 'Проверка того, что уведомления реально доставляются',
      importance: Importance.max,
      priority: Priority.high,
    );
    const details = NotificationDetails(android: androidDetails);
    await _plugin.show(0, 'фокус дерево 🌳', 'уведомления работают!', details);
  }

  // Не используем часовые пояса устройства напрямую (их не всегда можно
  // корректно определить без нативного плагина) — вместо этого переводим
  // нужное локальное время в UTC самостоятельно и планируем по UTC.
  static Future<void> scheduleDailyReminder({
    required int hour,
    required int minute,
  }) async {
    await cancelDailyReminder();

    const androidDetails = AndroidNotificationDetails(
      _dailyChannelId,
      'Ежедневные напоминания',
      channelDescription: 'Напоминание посадить дерево и сосредоточиться',
      importance: Importance.max,
      priority: Priority.high,
    );
    const details = NotificationDetails(android: androidDetails);

    final now = tz.TZDateTime.now(tz.local);
    var scheduled =
        tz.TZDateTime(tz.local, now.year, now.month, now.day, hour, minute);
    if (scheduled.isBefore(now)) {
      scheduled = scheduled.add(const Duration(days: 1));
    }

    try {
      await _plugin.zonedSchedule(
        1,
        'пора сосредоточиться 🌱',
        'посадите дерево и не отвлекайтесь',
        scheduled,
        details,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        matchDateTimeComponents: DateTimeComponents.time,
      );
    } catch (e) {
      // На части устройств (особенно Android 12+ без разрешения на точные
      // будильники) точная доставка недоступна — используем неточный режим,
      // это лучше, чем совсем без напоминаний.
      debugPrint('exact schedule failed, falling back to inexact: $e');
      try {
        await _plugin.zonedSchedule(
          1,
          'пора сосредоточиться 🌱',
          'посадите дерево и не отвлекайтесь',
          scheduled,
          details,
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          matchDateTimeComponents: DateTimeComponents.time,
        );
      } catch (e2) {
        debugPrint('inexact schedule also failed: $e2');
      }
    }
  }

  static Future<void> cancelDailyReminder() async {
    await _plugin.cancel(1);
  }
}

// ---------------------------------------------------------------------------
// Состояние приложения
// ---------------------------------------------------------------------------

class AppState extends ChangeNotifier {
  String userName = '';
  int selectedDuration = 25;
  String selectedSpeciesId = 'oak';

  bool notificationsEnabled = true;
  bool soundEnabled = true;
  bool vibrationEnabled = true;
  int reminderHour = 20;
  int reminderMinute = 0;

  final List<FocusSession> history = [];

  void setUserName(String name) {
    userName = name;
    notifyListeners();
    if (notificationsEnabled) {
      NotificationService.scheduleDailyReminder(hour: reminderHour, minute: reminderMinute);
    }
  }

  void setDuration(int minutes) {
    selectedDuration = minutes;
    notifyListeners();
  }

  void setSpecies(String id) {
    selectedSpeciesId = id;
    notifyListeners();
  }

  Future<void> toggleNotifications(bool value) async {
    notificationsEnabled = value;
    notifyListeners();
    if (value) {
      await NotificationService.scheduleDailyReminder(hour: reminderHour, minute: reminderMinute);
    } else {
      await NotificationService.cancelDailyReminder();
    }
  }

  Future<void> setReminderTime(int hour, int minute) async {
    reminderHour = hour;
    reminderMinute = minute;
    notifyListeners();
    if (notificationsEnabled) {
      await NotificationService.scheduleDailyReminder(hour: hour, minute: minute);
    }
  }

  void toggleSound(bool value) {
    soundEnabled = value;
    notifyListeners();
  }

  void toggleVibration(bool value) {
    vibrationEnabled = value;
    notifyListeners();
  }

  void addSession(FocusSession session) {
    history.insert(0, session);
    notifyListeners();
  }

  void clearHistory() {
    history.clear();
    notifyListeners();
  }

  bool isSpeciesUnlocked(TreeSpecies species) => successfulSessions >= species.unlockAt;

  int get totalSessions => history.length;

  int get successfulSessions => history.where((s) => s.success).length;

  int get totalFocusMinutes => history
      .where((s) => s.success)
      .fold(0, (sum, s) => sum + s.durationMinutes);

  double get successRate =>
      history.isEmpty ? 0 : successfulSessions / history.length;

  int get currentStreak {
    if (history.isEmpty) return 0;
    int streak = 0;
    DateTime? lastDay;
    for (final session in history) {
      if (!session.success) break;
      final day =
          DateTime(session.date.year, session.date.month, session.date.day);
      if (lastDay == null) {
        streak = 1;
        lastDay = day;
      } else {
        final diff = lastDay.difference(day).inDays;
        if (diff == 0) {
          continue;
        } else if (diff == 1) {
          streak++;
          lastDay = day;
        } else {
          break;
        }
      }
    }
    return streak;
  }
}

// ---------------------------------------------------------------------------
// Вспомогательные функции
// ---------------------------------------------------------------------------

String pluralizeRu(int n, String one, String few, String many) {
  final mod10 = n % 10;
  final mod100 = n % 100;
  if (mod10 == 1 && mod100 != 11) return one;
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 10 || mod100 >= 20)) return few;
  return many;
}

String formatMinutes(int totalMinutes) {
  final hours = totalMinutes ~/ 60;
  final minutes = totalMinutes % 60;
  if (hours == 0) return '$minutes мин';
  return '$hours ч $minutes мин';
}

IconData growthIcon(double growth, TreeSpecies species) {
  if (growth < 0.2) return Icons.grass_rounded;
  if (growth < 0.45) return Icons.eco_rounded;
  if (growth < 0.75) return Icons.park_outlined;
  return species.icon;
}

String formatTimeOfDay(int hour, int minute) {
  final h = hour.toString().padLeft(2, '0');
  final m = minute.toString().padLeft(2, '0');
  return '$h:$m';
}

void showAppSnackBar(
  BuildContext context,
  String message, {
  IconData icon = Icons.check_circle_rounded,
}) {
  final scheme = Theme.of(context).colorScheme;
  ScaffoldMessenger.of(context).hideCurrentSnackBar();
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      behavior: SnackBarBehavior.floating,
      backgroundColor: scheme.inverseSurface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      margin: const EdgeInsets.all(16),
      content: Row(
        children: [
          Icon(icon, color: scheme.onInverseSurface, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: scheme.onInverseSurface),
            ),
          ),
        ],
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// Корневой виджет
// ---------------------------------------------------------------------------

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final AppState appState = AppState();

  @override
  Widget build(BuildContext context) {
    final colorScheme =
        ColorScheme.fromSeed(seedColor: const Color(0xFF2E7D32));

    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'Фокус Дерево',
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: colorScheme,
            scaffoldBackgroundColor: colorScheme.surface,
            appBarTheme: AppBarTheme(
              backgroundColor: colorScheme.surface,
              foregroundColor: colorScheme.onSurface,
              elevation: 0,
              centerTitle: false,
              titleTextStyle: TextStyle(
                color: colorScheme.onSurface,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            filledButtonTheme: FilledButtonThemeData(
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(56),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
                textStyle:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
          ),
          home: appState.userName.isEmpty
              ? RegistrationScreen(appState: appState)
              : HomeScreen(appState: appState),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Экран регистрации
// ---------------------------------------------------------------------------

class RegistrationScreen extends StatefulWidget {
  final AppState appState;
  const RegistrationScreen({super.key, required this.appState});

  @override
  State<RegistrationScreen> createState() => _RegistrationScreenState();
}

class _RegistrationScreenState extends State<RegistrationScreen> {
  final TextEditingController _controller = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState!.validate()) {
      widget.appState.setUserName(_controller.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 120,
                    height: 120,
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer,
                      shape: BoxShape.circle,
                    ),
                    child:
                        Icon(Icons.park_rounded, size: 64, color: scheme.primary),
                  ),
                ),
                const SizedBox(height: 32),
                Text(
                  'фокус дерево',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'выращивайте деревья, оставаясь сосредоточенными',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 15, color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 40),
                Text(
                  'как вас зовут?',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: _controller,
                  textCapitalization: TextCapitalization.words,
                  maxLength: 20,
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: 'например, Марат',
                    filled: true,
                    fillColor: scheme.surfaceContainerHighest,
                    counterText: '',
                    prefixIcon: const Icon(Icons.person_outline_rounded),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'введите имя, чтобы продолжить';
                    }
                    return null;
                  },
                  onFieldSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _submit,
                  child: const Text('начать'),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Главный экран
// ---------------------------------------------------------------------------

class HomeScreen extends StatefulWidget {
  final AppState appState;
  const HomeScreen({super.key, required this.appState});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  bool _isFocusing = false;
  late int _totalSeconds;
  late int _secondsRemaining;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _totalSeconds = widget.appState.selectedDuration * 60;
    _secondsRemaining = _totalSeconds;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (_isFocusing &&
        (state == AppLifecycleState.paused ||
            state == AppLifecycleState.inactive)) {
      _killTree(reason: 'вы покинули приложение! дерево погибло 🥀');
    }
  }

  double get _growth =>
      _totalSeconds == 0 ? 0 : 1 - (_secondsRemaining / _totalSeconds);

  void _startFocus() {
    setState(() {
      _totalSeconds = widget.appState.selectedDuration * 60;
      _secondsRemaining = _totalSeconds;
      _isFocusing = true;
    });

    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {
        if (_secondsRemaining > 0) {
          _secondsRemaining--;
        } else {
          _finishFocus();
        }
      });
    });
  }

  void _finishFocus() {
    _timer?.cancel();
    final beforeCount = widget.appState.successfulSessions;
    widget.appState.addSession(FocusSession(
      date: DateTime.now(),
      durationMinutes: widget.appState.selectedDuration,
      success: true,
      speciesId: widget.appState.selectedSpeciesId,
    ));
    final afterCount = widget.appState.successfulSessions;
    final newlyUnlocked = treeSpecies
        .where((s) => s.unlockAt > beforeCount && s.unlockAt <= afterCount)
        .toList();

    if (widget.appState.soundEnabled) {
      SystemSound.play(SystemSoundType.click);
    }
    if (widget.appState.vibrationEnabled) {
      HapticFeedback.mediumImpact();
    }
    _isFocusing = false;

    if (newlyUnlocked.isNotEmpty) {
      showAppSnackBar(
        context,
        'новый вид открыт: ${newlyUnlocked.first.name}! 🎉',
        icon: Icons.auto_awesome_rounded,
      );
    } else {
      showAppSnackBar(
        context,
        'дерево выросло! отличная работа 🌳',
        icon: Icons.emoji_events_rounded,
      );
    }
  }

  void _killTree({required String reason}) {
    _timer?.cancel();
    widget.appState.addSession(FocusSession(
      date: DateTime.now(),
      durationMinutes: widget.appState.selectedDuration,
      success: false,
      speciesId: widget.appState.selectedSpeciesId,
    ));
    if (widget.appState.vibrationEnabled) {
      HapticFeedback.heavyImpact();
    }
    setState(() {
      _isFocusing = false;
    });
    showAppSnackBar(context, reason, icon: Icons.local_florist_rounded);
  }

  Future<void> _confirmGiveUp() async {
    final scheme = Theme.of(context).colorScheme;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('сдаться?'),
        content: const Text('если вы прервёте сеанс сейчас, дерево погибнет.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('продолжить'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: scheme.error),
            child: const Text('сдаться'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      _killTree(reason: 'вы сдались... дерево погибло 🥀');
    }
  }

  Future<void> _pickCustomDuration() async {
    double value = widget.appState.selectedDuration.toDouble().clamp(1, 180);
    await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final scheme = Theme.of(context).colorScheme;
            return AlertDialog(
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              title: const Text('своё время'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${value.round()} ${pluralizeRu(value.round(), 'минута', 'минуты', 'минут')}',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      color: scheme.primary,
                    ),
                  ),
                  Slider(
                    value: value,
                    min: 1,
                    max: 180,
                    divisions: 179,
                    onChanged: (v) => setDialogState(() => value = v),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('отмена'),
                ),
                FilledButton(
                  onPressed: () {
                    widget.appState.setDuration(value.round());
                    Navigator.pop(context);
                  },
                  child: const Text('готово'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildSpeciesSelector(ColorScheme scheme) {
    return SizedBox(
      height: 92,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: treeSpecies.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final species = treeSpecies[index];
          final unlocked = widget.appState.isSpeciesUnlocked(species);
          final selected = widget.appState.selectedSpeciesId == species.id;
          return GestureDetector(
            onTap: () {
              if (unlocked) {
                widget.appState.setSpecies(species.id);
              } else {
                showAppSnackBar(
                  context,
                  'откроется после ${species.unlockAt} ${pluralizeRu(species.unlockAt, 'дерева', 'деревьев', 'деревьев')}',
                  icon: Icons.lock_outline_rounded,
                );
              }
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              width: 78,
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: selected ? scheme.primaryContainer : scheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(18),
                border: selected ? Border.all(color: scheme.primary, width: 2) : null,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    unlocked ? species.icon : Icons.lock_outline_rounded,
                    color: unlocked ? species.color : scheme.onSurfaceVariant,
                    size: 26,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    species.name,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: unlocked ? scheme.onSurface : scheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const presets = [5, 10, 15, 25, 30, 45, 60];
    final species = speciesById(widget.appState.selectedSpeciesId);

    return WillPopScope(
      onWillPop: () async {
        if (_isFocusing) {
          _confirmGiveUp();
          return false;
        }
        return true;
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text('привет, ${widget.appState.userName}'),
          actions: [
            IconButton(
              icon: const Icon(Icons.bar_chart_rounded),
              tooltip: 'статистика',
              onPressed: _isFocusing
                  ? null
                  : () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) =>
                                StatsScreen(appState: widget.appState)),
                      ),
            ),
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: 'настройки',
              onPressed: _isFocusing
                  ? null
                  : () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) =>
                                SettingsScreen(appState: widget.appState)),
                      ),
            ),
          ],
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              children: [
                if (!_isFocusing) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'время фокуса',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      ...presets.map((minutes) => ChoiceChip(
                            label: Text('$minutes мин'),
                            selected: widget.appState.selectedDuration == minutes,
                            onSelected: (_) => widget.appState.setDuration(minutes),
                            selectedColor: scheme.primaryContainer,
                            labelStyle: TextStyle(
                              color: widget.appState.selectedDuration == minutes
                                  ? scheme.onPrimaryContainer
                                  : scheme.onSurfaceVariant,
                              fontWeight: FontWeight.w600,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                              side: BorderSide(color: scheme.outlineVariant),
                            ),
                          )),
                      ActionChip(
                        avatar: Icon(Icons.tune_rounded,
                            size: 18, color: scheme.onSurfaceVariant),
                        label: Text(
                          presets.contains(widget.appState.selectedDuration)
                              ? 'своё'
                              : '${widget.appState.selectedDuration} мин',
                        ),
                        onPressed: _pickCustomDuration,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                          side: BorderSide(color: scheme.outlineVariant),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'вид дерева',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  _buildSpeciesSelector(scheme),
                  const SizedBox(height: 18),
                ],
                Expanded(
                  child: Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(28),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 400),
                          padding: const EdgeInsets.all(34),
                          decoration: BoxDecoration(
                            color: Color.lerp(
                                scheme.primaryContainer, species.color, _growth * 0.4),
                            shape: BoxShape.circle,
                          ),
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 300),
                            child: Icon(
                              growthIcon(_growth, species),
                              key: ValueKey('${species.id}-${growthIcon(_growth, species)}'),
                              size: 84,
                              color: _growth >= 0.75 ? species.color : scheme.primary,
                            ),
                          ),
                        ),
                        const SizedBox(height: 28),
                        Text(
                          _isFocusing
                              ? '${_secondsRemaining ~/ 60}:${(_secondsRemaining % 60).toString().padLeft(2, '0')}'
                              : 'посадите ${species.name} на ${widget.appState.selectedDuration} ${pluralizeRu(widget.appState.selectedDuration, 'минуту', 'минуты', 'минут')}',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            color: scheme.onSurface,
                          ),
                        ),
                        if (_isFocusing) ...[
                          const SizedBox(height: 18),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 44),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: LinearProgressIndicator(
                                value: _growth,
                                minHeight: 8,
                                backgroundColor: scheme.surfaceContainerHighest,
                                color: scheme.primary,
                              ),
                            ),
                          ),
                          const SizedBox(height: 14),
                          Text(
                            'не выходите из приложения — дерево может погибнуть',
                            style:
                                TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: _isFocusing
                      ? OutlinedButton(
                          onPressed: _confirmGiveUp,
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(56),
                            foregroundColor: scheme.error,
                            side: BorderSide(color: scheme.error.withOpacity(0.4)),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(18)),
                          ),
                          child: const Text('сдаться',
                              style: TextStyle(fontWeight: FontWeight.w700)),
                        )
                      : FilledButton.icon(
                          onPressed: _startFocus,
                          icon: const Icon(Icons.eco_rounded),
                          label: const Text('посадить дерево'),
                        ),
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Экран статистики и леса
// ---------------------------------------------------------------------------

class StatsScreen extends StatelessWidget {
  final AppState appState;
  const StatsScreen({super.key, required this.appState});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final history = appState.history;
        return Scaffold(
          appBar: AppBar(title: const Text('статистика')),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                GridView.count(
                  crossAxisCount: 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 14,
                  crossAxisSpacing: 14,
                  childAspectRatio: 1.4,
                  children: [
                    _StatCard(
                      icon: Icons.park_rounded,
                      label: 'деревьев выросло',
                      value: '${appState.successfulSessions}',
                    ),
                    _StatCard(
                      icon: Icons.timer_outlined,
                      label: 'время в фокусе',
                      value: formatMinutes(appState.totalFocusMinutes),
                    ),
                    _StatCard(
                      icon: Icons.local_fire_department_rounded,
                      label: 'серия дней',
                      value: '${appState.currentStreak}',
                    ),
                    _StatCard(
                      icon: Icons.percent_rounded,
                      label: 'успешных сеансов',
                      value: '${(appState.successRate * 100).round()}%',
                    ),
                  ],
                ),
                const SizedBox(height: 28),
                Text(
                  'мой лес',
                  style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700, color: scheme.onSurface),
                ),
                const SizedBox(height: 12),
                if (history.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(28),
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Column(
                      children: [
                        Icon(Icons.forest_outlined, size: 40, color: scheme.onSurfaceVariant),
                        const SizedBox(height: 10),
                        Text(
                          'пока нет посаженных деревьев',
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  )
                else
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 5,
                      mainAxisSpacing: 10,
                      crossAxisSpacing: 10,
                    ),
                    itemCount: history.length,
                    itemBuilder: (context, index) {
                      final session = history[index];
                      final species = speciesById(session.speciesId);
                      return Tooltip(
                        message:
                            '${session.date.day}.${session.date.month}.${session.date.year} · ${session.durationMinutes} мин',
                        child: Container(
                          decoration: BoxDecoration(
                            color: session.success
                                ? species.color.withOpacity(0.18)
                                : scheme.errorContainer.withOpacity(0.5),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Icon(
                            session.success
                                ? species.icon
                                : Icons.local_florist_outlined,
                            color: session.success ? species.color : scheme.onErrorContainer,
                          ),
                        ),
                      );
                    },
                  ),
                const SizedBox(height: 28),
                Text(
                  'виды деревьев',
                  style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700, color: scheme.onSurface),
                ),
                const SizedBox(height: 12),
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: 0.95,
                  ),
                  itemCount: treeSpecies.length,
                  itemBuilder: (context, index) {
                    final species = treeSpecies[index];
                    final unlocked = appState.isSpeciesUnlocked(species);
                    return Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            unlocked ? species.icon : Icons.lock_outline_rounded,
                            color: unlocked ? species.color : scheme.onSurfaceVariant,
                            size: 26,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            species.name,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: unlocked ? scheme.onSurface : scheme.onSurfaceVariant,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          if (!unlocked) ...[
                            const SizedBox(height: 2),
                            Text(
                              '${species.unlockAt} ${pluralizeRu(species.unlockAt, 'дерево', 'дерева', 'деревьев')}',
                              style:
                                  TextStyle(fontSize: 9, color: scheme.onSurfaceVariant),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ],
                      ),
                    );
                  },
                ),
                const SizedBox(height: 28),
                if (history.isNotEmpty) ...[
                  Text(
                    'история',
                    style: TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700, color: scheme.onSurface),
                  ),
                  const SizedBox(height: 12),
                  ...history.take(20).map((session) {
                    final species = speciesById(session.speciesId);
                    return Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            session.success
                                ? Icons.check_circle_rounded
                                : Icons.cancel_rounded,
                            color: session.success ? species.color : scheme.error,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              '${species.name} · ${session.durationMinutes} ${pluralizeRu(session.durationMinutes, 'минута', 'минуты', 'минут')} · ${session.date.day}.${session.date.month.toString().padLeft(2, '0')}.${session.date.year}',
                              style: TextStyle(color: scheme.onSurface),
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _StatCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _StatCard({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: scheme.primary, size: 24),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: scheme.onSurface),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Экран настроек
// ---------------------------------------------------------------------------

class SettingsScreen extends StatelessWidget {
  final AppState appState;
  const SettingsScreen({super.key, required this.appState});

  Future<void> _editName(BuildContext context) async {
    final controller = TextEditingController(text: appState.userName);
    final scheme = Theme.of(context).colorScheme;
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('изменить имя'),
        content: TextField(
          controller: controller,
          maxLength: 20,
          autofocus: true,
          decoration: InputDecoration(
            filled: true,
            fillColor: scheme.surfaceContainerHighest,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('отмена')),
          FilledButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                appState.setUserName(name);
              }
              Navigator.pop(context);
            },
            child: const Text('сохранить'),
          ),
        ],
      ),
    );
  }

  Future<void> _pickReminderTime(BuildContext context) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: appState.reminderHour, minute: appState.reminderMinute),
    );
    if (picked != null) {
      await appState.setReminderTime(picked.hour, picked.minute);
      if (context.mounted) {
        showAppSnackBar(context, 'время напоминания обновлено', icon: Icons.alarm_rounded);
      }
    }
  }

  Future<void> _sendTestNotification(BuildContext context) async {
    await NotificationService.showTestNotification();
    if (context.mounted) {
      showAppSnackBar(
        context,
        'уведомление отправлено — проверьте шторку',
        icon: Icons.notifications_active_rounded,
      );
    }
  }

  Future<void> _confirmClearHistory(BuildContext context) async {
    final scheme = Theme.of(context).colorScheme;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('очистить лес?'),
        content: const Text(
            'вся история посаженных деревьев будет удалена без возможности восстановления.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('отмена')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: scheme.error),
            child: const Text('очистить'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      appState.clearHistory();
      if (context.mounted) {
        showAppSnackBar(context, 'лес очищен', icon: Icons.delete_outline_rounded);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        return Scaffold(
          appBar: AppBar(title: const Text('настройки')),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      backgroundColor: scheme.primaryContainer,
                      child: Icon(Icons.person_rounded, color: scheme.primary),
                    ),
                    title: Text(appState.userName, style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: const Text('изменить имя'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => _editName(context),
                  ),
                ),
                const SizedBox(height: 24),
                Text('уведомления',
                    style: TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700, color: scheme.onSurfaceVariant)),
                const SizedBox(height: 8),
                Container(
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Column(
                    children: [
                      SwitchListTile(
                        title: const Text('ежедневное напоминание'),
                        subtitle: const Text('напоминать посадить дерево'),
                        value: appState.notificationsEnabled,
                        onChanged: (v) => appState.toggleNotifications(v),
                        secondary: const Icon(Icons.notifications_outlined),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.alarm_rounded),
                        title: const Text('время напоминания'),
                        subtitle: Text(formatTimeOfDay(appState.reminderHour, appState.reminderMinute)),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        enabled: appState.notificationsEnabled,
                        onTap: () => _pickReminderTime(context),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.send_rounded),
                        title: const Text('отправить тестовое уведомление'),
                        subtitle: const Text('проверьте, что уведомления реально приходят'),
                        onTap: () => _sendTestNotification(context),
                      ),
                      const Divider(height: 1),
                      SwitchListTile(
                        title: const Text('звук'),
                        subtitle: const Text('звук при завершении сеанса'),
                        value: appState.soundEnabled,
                        onChanged: appState.toggleSound,
                        secondary: const Icon(Icons.volume_up_outlined),
                      ),
                      const Divider(height: 1),
                      SwitchListTile(
                        title: const Text('вибрация'),
                        subtitle: const Text('вибрация при событиях'),
                        value: appState.vibrationEnabled,
                        onChanged: appState.toggleVibration,
                        secondary: const Icon(Icons.vibration_rounded),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    'если уведомления не приходят: откройте настройки телефона → приложения → фокус дерево → уведомления, и отключите ограничение батареи/автозапуска (особенно на Xiaomi, Huawei, Honor).',
                    style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant, height: 1.4),
                  ),
                ),
                const SizedBox(height: 24),
                Text('данные',
                    style: TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700, color: scheme.onSurfaceVariant)),
                const SizedBox(height: 8),
                Container(
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: ListTile(
                    leading: Icon(Icons.delete_outline_rounded, color: scheme.error),
                    title: Text('очистить историю леса', style: TextStyle(color: scheme.error)),
                    onTap: () => _confirmClearHistory(context),
                  ),
                ),
                const SizedBox(height: 24),
                Center(
                  child: Column(
                    children: [
                      Icon(Icons.park_rounded, color: scheme.onSurfaceVariant),
                      const SizedBox(height: 6),
                      Text('фокус дерево · v1.1',
                          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
