import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../../core/api/api_client.dart';
import '../../core/locale/app_language.dart';

class BedtimeStep {
  const BedtimeStep({required this.title, required this.emoji});

  factory BedtimeStep.fromJson(Map<String, dynamic> j) => BedtimeStep(title: j['title'] as String, emoji: j['emoji'] as String? ?? '⭐');

  final String title;
  final String emoji;

  Map<String, dynamic> toJson() => {'title': title, 'emoji': emoji};
}

/// Tonight on the child's phone.
class ChildBedtime {
  const ChildBedtime(
      {required this.time, required this.steps, this.open = false, this.done = 0, this.finishedAt, this.cherries = 0, this.lockUntilMorning = true});

  factory ChildBedtime.fromJson(Map<String, dynamic> j) => ChildBedtime(
        time: j['time'] as String,
        steps: [for (final s in j['steps'] as List) BedtimeStep.fromJson(s as Map<String, dynamic>)],
        open: j['open'] as bool? ?? false,
        done: (j['done'] as num?)?.toInt() ?? 0,
        finishedAt: j['finishedAt'] == null ? null : DateTime.parse(j['finishedAt'] as String),
        cherries: (j['cherries'] as num?)?.toInt() ?? 0,
        lockUntilMorning: j['lockUntilMorning'] as bool? ?? true,
      );

  /// "HH:mm".
  final String time;
  final List<BedtimeStep> steps;
  final bool open;
  final int done;
  final DateTime? finishedAt;
  final int cherries;
  final bool lockUntilMorning;

  bool get finished => finishedAt != null;

  /// The routine waits for the child: open and not finished.
  bool get due => open && !finished;
}

class BedtimeRoutine {
  const BedtimeRoutine({required this.time, required this.steps, this.enabled = true, this.lockUntilMorning = true, this.cherries = 3});

  factory BedtimeRoutine.fromJson(Map<String, dynamic> j) => BedtimeRoutine(
        time: j['time'] as String,
        steps: [for (final s in j['steps'] as List) BedtimeStep.fromJson(s as Map<String, dynamic>)],
        enabled: j['enabled'] as bool? ?? true,
        lockUntilMorning: j['lockUntilMorning'] as bool? ?? true,
        cherries: (j['cherries'] as num?)?.toInt() ?? 3,
      );

  final String time;
  final List<BedtimeStep> steps;
  final bool enabled;
  final bool lockUntilMorning;
  final int cherries;

  Map<String, dynamic> toJson() => {
        'time': time,
        'steps': [for (final s in steps) s.toJson()],
        'enabled': enabled,
        'lockUntilMorning': lockUntilMorning,
        'cherries': cherries
      };
}

class BedtimeState {
  const BedtimeState({this.routine, this.tonightDone = 0, this.tonightTotal = 0, this.tonightFinishedAt});

  factory BedtimeState.fromJson(Map<String, dynamic> j) {
    final t = j['tonight'] as Map<String, dynamic>?;
    return BedtimeState(
      routine: j['routine'] == null ? null : BedtimeRoutine.fromJson(j['routine'] as Map<String, dynamic>),
      tonightDone: (t?['done'] as num?)?.toInt() ?? 0,
      tonightTotal: (t?['total'] as num?)?.toInt() ?? 0,
      tonightFinishedAt: t?['finishedAt'] == null ? null : DateTime.parse(t!['finishedAt'] as String),
    );
  }

  final BedtimeRoutine? routine;
  final int tonightDone;
  final int tonightTotal;
  final DateTime? tonightFinishedAt;
}

abstract interface class BedtimeRepository {
  Future<BedtimeState> load(String familyId, String childId);
  Future<BedtimeState> save(String familyId, String childId, BedtimeRoutine routine);
}

class ApiBedtimeRepository implements BedtimeRepository {
  ApiBedtimeRepository(this._api);

  final ApiClient _api;

  String _url(String familyId, String childId) => '/api/v1/families/$familyId/children/$childId/bedtime';

  @override
  Future<BedtimeState> load(String familyId, String childId) async {
    try {
      return BedtimeState.fromJson((await _api.dio.get<Map<String, dynamic>>(_url(familyId, childId))).data!);
    } catch (e) {
      throw ApiClient.toApiException(e);
    }
  }

  @override
  Future<BedtimeState> save(String familyId, String childId, BedtimeRoutine routine) async {
    try {
      return BedtimeState.fromJson((await _api.dio.put<Map<String, dynamic>>(_url(familyId, childId), data: routine.toJson())).data!);
    } catch (e) {
      throw ApiClient.toApiException(e);
    }
  }
}

final bedtimeRepositoryProvider = Provider<BedtimeRepository>((ref) => ApiBedtimeRepository(ref.watch(apiClientProvider)));

final bedtimeProvider =
    FutureProvider.autoDispose.family<BedtimeState, (String, String)>((ref, key) => ref.watch(bedtimeRepositoryProvider).load(key.$1, key.$2));

/// The child tapped "Sonra" on tonight's steps; the Bugünüm card brings them back.
final bedtimeLaterProvider = StateProvider<bool>((ref) => false);

/// Reads the story aloud with the phone's own voice. Swappable in tests.
abstract interface class StorySpeaker {
  Future<void> speak(String text, {required String language, required void Function() onDone});
  Future<void> stop();
}

class TtsStorySpeaker implements StorySpeaker {
  TtsStorySpeaker({this.rate = 0.42});

  /// Slow and calm for a bedtime story; the morning summary reads a little faster.
  final double rate;
  final _tts = FlutterTts();

  @override
  Future<void> speak(String text, {required String language, required void Function() onDone}) async {
    await _tts.setLanguage(speechLocaleFor(language).replaceAll('_', '-'));
    await _tts.setSpeechRate(rate);
    await _tts.setPitch(1.0);
    _tts.setCompletionHandler(onDone);
    await _tts.speak(text);
  }

  @override
  Future<void> stop() => _tts.stop();
}

final storySpeakerProvider = Provider<StorySpeaker>((ref) => TtsStorySpeaker());

class BedtimeStory {
  const BedtimeStory(this.title, this.text);

  final String title;
  final String text;
}

/// A short story for tonight: the same all evening, another one tomorrow.
BedtimeStory storyFor(DateTime evening, String language) {
  final list = _stories[language] ?? _storiesEn;
  final day = evening.difference(DateTime(2026)).inDays;
  return list[day % list.length];
}

const _stories = {'tr': _storiesTr, 'en': _storiesEn, 'de': _storiesDe, 'ja': _storiesJa};

const _storiesTr = [
  BedtimeStory(
      'Uykucu Ayıcık ve Ay Feneri',
      'Ormanın ucundaki küçük evde, Ayıcık her akşam fenerini yakar ve yıldızları tek tek sayardı. Bir gece bir yıldızın eksik olduğunu fark etti. '
          'Fenerini alıp bahçeye çıktı ve çimenlerin arasında parlayan küçük bir ışık gördü. Bu, yorulup dinlenmeye inen minik bir yıldızdı. '
          'Ayıcık yıldızı avucuna aldı, ona sıcak bir battaniye gibi sarıldı ve bir ninni mırıldandı. Yıldız dinlenince yavaşça gökyüzüne geri yükseldi. '
          'Ayıcık esneyerek yatağına döndü. O gece gökyüzündeki bütün yıldızlar onun için biraz daha parlak ışıldadı. İyi geceler.'),
  BedtimeStory(
      'Bulut Pamuk',
      'Pamuk adında yumuşacık bir bulut, bütün gün gökyüzünde gezip çocuklara gölge yapmıştı. Akşam olunca rüzgâr ona fısıldadı: Dinlenme vakti. '
          'Pamuk dağların üstüne uzandı, güneş ona turuncu bir yorgan örttü. Kuşlar yuvalarına, tavşanlar yuvalarına döndü. '
          'Ay yükselince Pamuk gümüş renge büründü ve usulca gözlerini kapadı. Yarın yine birlikte oynayacaklardı. Şimdi her şey sessiz ve huzurlu. İyi geceler.'),
  BedtimeStory(
      'Minik Kaplumbağanın Yolculuğu',
      'Minik kaplumbağa, deniz kıyısında bütün gün yavaş yavaş yürüdü. Yolda bir deniz kabuğu, bir yengeç ve parlak bir taş gördü. '
          'Akşam olunca dalgalar ona ninni söylemeye başladı: şşş, şşş. Kaplumbağa kumların arasına sıcak bir yuva yaptı. '
          'Başını kabuğunun içine çekti ve bugün gördüğü güzel şeyleri düşündü. Dalgaların sesi gittikçe yavaşladı. Kaplumbağa da sen de, derin bir nefes alıp uykuya dalabilirsiniz. İyi geceler.'),
  BedtimeStory(
      'Kedi Fıstık ve Sessiz Ev',
      'Fıstık adındaki kedi, evdeki herkes uyumadan önce son bir tur atardı. Mutfakta ışıkların sönmüş olduğuna baktı. Oyuncakların kutularında olduğunu gördü. '
          'Pencereden ayı selamladı ve kuyruğunu dolayarak minderine kıvrıldı. Evin içinde sadece saatin tık tık sesi vardı. '
          'Fıstık mırlamaya başladı; mırıltısı yumuşak ve sıcaktı. Herkes güvendeydi, her şey yerli yerindeydi. Fıstık gözlerini kapattı. Sen de kapatabilirsin. İyi geceler.'),
  BedtimeStory(
      'Rüya Treni',
      'Her gece saat dokuzda, yıldızların arasından küçük bir rüya treni geçer. Vagonları yumuşak yastıklarla doludur. '
          'Bilet olarak sadece güzel bir düşünce gerekir. Bugün seni mutlu eden bir şeyi düşün; işte biletin hazır. '
          'Tren yavaşça hareket eder, tekerlekleri tıkır tıkır ninni çalar. Pencereden bulutlar, ay ve uçan balıklar görünür. Başını yastığa koy ve trenin seni götürmesine izin ver. İyi geceler.'),
];

const _storiesEn = [
  BedtimeStory(
      'Sleepy Bear and the Moon Lantern',
      'In a little house at the edge of the forest, Bear lit his lantern every evening and counted the stars one by one. One night a star was missing. '
          'He took his lantern into the garden and found a tiny light glowing in the grass: a little star resting after a long day. '
          'Bear held it gently, hummed a lullaby, and when the star had rested it floated slowly back into the sky. '
          'Bear yawned and went back to bed. That night every star shone a little brighter for him. Good night.'),
  BedtimeStory(
      'Cotton the Cloud',
      'A soft cloud called Cotton had spent all day drifting across the sky, giving shade to children at play. When evening came, the wind whispered: time to rest. '
          'Cotton lay down over the hills, and the sun tucked her in with an orange blanket. The birds flew home, the rabbits hopped home. '
          'When the moon rose, Cotton turned silver and quietly closed her eyes. Tomorrow they would play again. Now all is calm and quiet. Good night.'),
  BedtimeStory(
      'Little Turtle\'s Walk',
      'Little Turtle walked slowly along the beach all day. He saw a shell, a crab and a shiny stone. '
          'In the evening the waves began to sing him a lullaby: shhh, shhh. Turtle made a warm nest in the sand. '
          'He tucked his head into his shell and thought about all the lovely things he had seen. The waves grew slower and softer. Take a deep breath, just like Turtle, and drift off to sleep. Good night.'),
];

const _storiesDe = [
  BedtimeStory(
      'Der kleine Bär und die Mondlaterne',
      'In einem kleinen Haus am Waldrand zündete der kleine Bär jeden Abend seine Laterne an und zählte die Sterne, einen nach dem anderen. Eines Nachts fehlte ein Stern. '
          'Er ging mit der Laterne in den Garten und fand im Gras ein winziges Licht: einen kleinen Stern, der sich nach einem langen Tag ausruhte. '
          'Der Bär hielt ihn sanft in den Pfoten und summte ein Schlaflied. Als der Stern sich ausgeruht hatte, schwebte er langsam zurück in den Himmel. '
          'Der Bär gähnte und kroch wieder ins Bett. In dieser Nacht leuchteten alle Sterne ein bisschen heller für ihn. Gute Nacht.'),
  BedtimeStory(
      'Watte, die kleine Wolke',
      'Eine weiche Wolke namens Watte war den ganzen Tag über den Himmel gezogen und hatte den spielenden Kindern Schatten gespendet. Am Abend flüsterte der Wind: Zeit zum Ausruhen. '
          'Watte legte sich über die Hügel, und die Sonne deckte sie mit einer orangefarbenen Decke zu. Die Vögel flogen nach Hause, die Hasen hoppelten nach Hause. '
          'Als der Mond aufging, wurde Watte silbern und schloss leise die Augen. Morgen würden sie wieder zusammen spielen. Jetzt ist alles still und friedlich. Gute Nacht.'),
  BedtimeStory(
      'Die kleine Schildkröte',
      'Die kleine Schildkröte spazierte den ganzen Tag langsam am Strand entlang. Sie sah eine Muschel, eine Krabbe und einen glänzenden Stein. '
          'Am Abend begannen die Wellen, ihr ein Schlaflied zu singen: schhh, schhh. Die Schildkröte baute sich ein warmes Nest im Sand. '
          'Sie zog den Kopf in ihren Panzer und dachte an all die schönen Dinge, die sie gesehen hatte. Die Wellen wurden langsamer und leiser. Atme tief ein, genau wie die Schildkröte, und schlaf langsam ein. Gute Nacht.'),
];

const _storiesJa = [
  BedtimeStory(
      'くまさんとお月さまのランタン',
      '森のはずれの小さな家で、くまさんは毎晩ランタンに明かりをつけて、星をひとつずつ数えていました。ある夜、星がひとつ足りません。'
          'くまさんがランタンを持って庭に出ると、草の中に小さな光が見えました。長い一日でつかれて、ひと休みしている小さな星でした。'
          'くまさんは星をそっと手にのせて、子もり歌をハミングしました。星は元気になると、ゆっくり空へ帰っていきました。'
          'くまさんはあくびをして、ベッドにもどりました。その夜、空の星はみんな、くまさんのために少しだけ明るく光りました。おやすみなさい。'),
  BedtimeStory(
      'くものわたちゃん',
      'わたちゃんという、ふわふわのくもがいました。一日じゅう空をただよって、遊んでいる子どもたちにかげを作っていました。夕方になると、風がささやきました。休む時間だよ。'
          'わたちゃんが山の上に横になると、お日さまがオレンジ色のふとんをかけてくれました。鳥たちも、うさぎたちも、おうちに帰りました。'
          'お月さまがのぼると、わたちゃんは銀色になって、そっと目をとじました。あしたもまた一緒に遊ぼうね。いまは、みんな静かでおだやかです。おやすみなさい。'),
  BedtimeStory(
      'ちいさなかめのおさんぽ',
      'ちいさなかめは、一日じゅう浜辺をゆっくり歩きました。貝がらと、かにと、ぴかぴかの石を見つけました。'
          '夕方になると、波が子もり歌を歌いはじめました。ざざーん、ざざーん。かめは砂の中にあたたかい寝床を作りました。'
          '頭をこうらの中にしまって、今日見たすてきなものを思い出しました。波の音はだんだんゆっくり、静かになりました。かめと同じように深く息をすって、ゆっくりねむりましょう。おやすみなさい。'),
];
