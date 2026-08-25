import 'package:flutter/material.dart';
import 'package:miru/bean/dialog/adaptive_bottom_sheet.dart';
import 'package:miru/bean/widget/bangumi_avatar.dart';
import 'package:miru/modules/characters/character_item.dart';
import 'package:miru/pages/info/character_page.dart';

class CharacterCard extends StatelessWidget {
  const CharacterCard({
    super.key,
    required this.characterItem,
  });

  final CharacterItem characterItem;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: BangumiAvatar(
        imageUrl: characterItem.avator.grid,
      ),
      title: Text(
        characterItem.name,
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
      ),
      subtitle: characterItem.actorList.isNotEmpty
          ? Text(characterItem.actorList[0].name)
          : null,
      trailing: Text(characterItem.relation),
      onTap: () {
        showAdaptiveBottomSheet<void>(
          context: context,
          builder: (context) {
            return CharacterPage(
              characterID: characterItem.id,
              characterName: characterItem.name,
              characterRelation: characterItem.relation,
            );
          },
        );
      },
    );
  }
}
