import 'package:flutter_test/flutter_test.dart';
import 'package:sado/features/chat/screen_effects.dart';
import 'package:tdlib_ex/td_api.dart' as td;

td.MessageInteractionInfo _info(Map<String, int> counts, {Set<String> mine = const {}}) => td.MessageInteractionInfo(
      viewCount: 0,
      forwardCount: 0,
      replyInfo: null,
      reactions: td.MessageReactions(
        reactions: [
          for (final MapEntry(key: emoji, value: count) in counts.entries)
            td.MessageReaction(type: td.ReactionTypeEmoji(emoji: emoji), totalCount: count, isChosen: mine.contains(emoji), usedSenderId: null, recentSenderIds: const []),
        ],
        areTags: false,
        paidReactors: const [],
        canGetAddedReactions: false,
      ),
    );

void main() {
  group('effectForText', () {
    test('keywords pick their effect, any case and apostrophe', () {
      expect(effectForText('Tabriklayman!'), ScreenEffect.confetti);
      expect(effectForText('Tugʻilgan kuning bilan, doʻstim'), ScreenEffect.confetti);
      expect(effectForText('Bayramingiz muborak'), ScreenEffect.confetti);
      expect(effectForText('Katta rahmat'), ScreenEffect.hearts);
      expect(effectForText('seni yaxshi ko’raman'), ScreenEffect.hearts);
      expect(effectForText('Bu DAXSHAT'), ScreenEffect.fire);
      expect(effectForText("Yong'in chiqdi"), ScreenEffect.fire);
      expect(effectForText('nima bu 😡'), ScreenEffect.anger);
      expect(effectForText('🤬🤬'), ScreenEffect.anger);
    });

    test('ordinary, mid-word and long texts do nothing', () {
      expect(effectForText('Salom, qalaysan?'), isNull);
      expect(effectForText('nomuborak ish'), isNull);
      expect(effectForText('rahmat ${'a' * 400}'), isNull);
      expect(effectForText(''), isNull);
    });
  });

  test('reaction emoji with or without the variation selector', () {
    expect(effectForReaction('❤️'), ScreenEffect.hearts);
    expect(effectForReaction('❤'), ScreenEffect.hearts);
    expect(effectForReaction('🔥'), ScreenEffect.fire);
    expect(effectForReaction('🎉'), ScreenEffect.confetti);
    expect(effectForReaction('😡'), ScreenEffect.anger);
    expect(effectForReaction('🤬'), ScreenEffect.anger);
    expect(effectForReaction('👍'), isNull);
  });

  test('only a reaction this user just added plays', () {
    expect(effectForNewReaction(null, _info({'❤️': 1}, mine: {'❤️'})), ScreenEffect.hearts);
    expect(effectForNewReaction(_info({'🔥': 2}), _info({'🔥': 3}, mine: {'🔥'})), ScreenEffect.fire);
    expect(effectForNewReaction(_info({'🔥': 3}, mine: {'🔥'}), _info({'🔥': 2})), isNull);
    expect(effectForNewReaction(_info({'👍': 1}), _info({'👍': 2}, mine: {'👍'})), isNull);
  });

  test("other people's reactions never play, even ones that grew while away", () {
    expect(effectForNewReaction(null, _info({'❤️': 40})), isNull);
    expect(effectForNewReaction(_info({'❤️': 5}), _info({'❤️': 6})), isNull);
    expect(effectForNewReaction(_info({'❤️': 5}, mine: {'❤️'}), _info({'❤️': 6}, mine: {'❤️'})), isNull);
  });
}
