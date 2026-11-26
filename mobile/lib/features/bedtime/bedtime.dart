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

const _stories = {'tr': _storiesTr, 'en': _storiesEn, 'de': _storiesDe, 'ja': _storiesJa, 'ko': _storiesKo, 'zh': _storiesZh};

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

const _storiesKo = [
  BedtimeStory(
      '졸린 곰과 달빛 등불',
      '숲 끝의 작은 집에서 곰은 저녁마다 등불을 켜고 별을 하나씩 세었어요. 어느 날 밤, 별 하나가 보이지 않았어요. '
          '곰은 등불을 들고 마당으로 나갔고, 풀숲에서 반짝이는 작은 빛을 찾았어요. 긴 하루를 보내고 쉬고 있던 작은 별이었어요. '
          '곰은 별을 살며시 감싸 안고 자장가를 흥얼거렸어요. 별은 푹 쉬고 나서 천천히 하늘로 돌아갔어요. '
          '곰은 하품을 하며 침대로 돌아왔어요. 그날 밤 하늘의 별들은 모두 곰을 위해 조금 더 밝게 빛났어요. 잘 자요.'),
  BedtimeStory(
      '구름 솜이',
      '솜이라는 폭신한 구름은 하루 종일 하늘을 떠다니며 놀고 있는 아이들에게 그늘을 만들어 주었어요. 저녁이 되자 바람이 속삭였어요. 이제 쉴 시간이야. '
          '솜이는 언덕 위에 누웠고, 해님은 주황색 이불을 덮어 주었어요. 새들도 토끼들도 집으로 돌아갔어요. '
          '달이 뜨자 솜이는 은빛이 되어 살며시 눈을 감았어요. 내일 또 같이 놀자. 지금은 모든 것이 조용하고 평화로워요. 잘 자요.'),
  BedtimeStory(
      '아기 거북의 산책',
      '아기 거북은 하루 종일 바닷가를 천천히 걸었어요. 조개껍데기와 게, 반짝이는 돌을 보았어요. '
          '저녁이 되자 파도가 자장가를 불러 주었어요. 쏴아, 쏴아. 거북은 모래 속에 따뜻한 잠자리를 만들었어요. '
          '머리를 등딱지 속에 넣고 오늘 본 예쁜 것들을 떠올렸어요. 파도 소리는 점점 느리고 조용해졌어요. 거북처럼 숨을 깊이 쉬고 스르르 잠들어 봐요. 잘 자요.'),
];

const _storiesZh = [
  BedtimeStory(
      '小熊和月亮灯笼',
      '在森林边上的小房子里，小熊每天晚上都会点亮灯笼，一颗一颗地数星星。有一天晚上，少了一颗星星。'
          '小熊提着灯笼来到院子里，在草丛里发现了一点小小的光：原来是一颗累了一天、正在休息的小星星。'
          '小熊轻轻地捧着它，哼起了摇篮曲。小星星休息好以后，慢慢地飘回了天上。'
          '小熊打了个哈欠，回到床上。那天晚上，天上所有的星星都为它亮得更闪了一点。晚安。'),
  BedtimeStory(
      '小云朵棉棉',
      '一朵叫棉棉的软软的云，在天上飘了一整天，给玩耍的孩子们遮阴。傍晚到了，风轻轻地说：该休息啦。'
          '棉棉躺在山坡上，太阳给它盖上了一条橙色的被子。小鸟飞回了家，小兔子也跳回了家。'
          '月亮升起来了，棉棉变成了银色，轻轻地闭上了眼睛。明天还要一起玩呢。现在，一切都安静又平和。晚安。'),
  BedtimeStory(
      '小乌龟散步',
      '小乌龟在海边慢慢地走了一整天。它看到了一个贝壳、一只螃蟹和一块亮晶晶的石头。'
          '傍晚，海浪开始给它唱摇篮曲：哗——哗——。小乌龟在沙子里做了一个暖暖的窝。'
          '它把头缩进壳里，想着今天看到的美好的东西。海浪声越来越慢，越来越轻。像小乌龟一样深深地吸一口气，慢慢睡着吧。晚安。'),
];
