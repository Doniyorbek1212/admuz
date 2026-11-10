import 'package:flutter_test/flutter_test.dart';
import 'package:sado/features/chat/screen_effects.dart';
import 'package:tdlib_ex/td_api.dart' as td;

td.MessageInteractionInfo _info(Map<String, int> counts) => td.MessageInteractionInfo(
      viewCount: 0,
      forwardCount: 0,
      replyInfo: null,
      reactions: td.MessageReactions(
        reactions: [
          for (final MapEntry(key: emoji, value: count) in counts.entries)
            td.MessageReaction(type: td.ReactionTypeEmoji(emoji: emoji), totalCount: count, isChosen: false, usedSenderId: null, recentSenderIds: const []),
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
    expect(effectForReaction('👍'), isNull);
  });

  test('only a reaction that was just added plays', () {
    expect(effectForNewReaction(null, _info({'❤️': 1})), ScreenEffect.hearts);
    expect(effectForNewReaction(_info({'🔥': 2}), _info({'🔥': 3})), ScreenEffect.fire);
    expect(effectForNewReaction(_info({'🔥': 3}), _info({'🔥': 2})), isNull);
    expect(effectForNewReaction(_info({'👍': 1}), _info({'👍': 2})), isNull);
  });
}
