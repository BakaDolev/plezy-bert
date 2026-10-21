import 'package:flutter/material.dart';

import '../services/enrichment/person_online_page.dart';

/// A poster card for one online [PersonCredit] — used by the actor page's
/// "Known For" row. Shows the poster, title, the character played, and the
/// year.
///
/// Tappable only when [onTap] is supplied — the actor page wires it for titles
/// that are in your library (opening the local item), matching how the
/// filmography rows link owned titles and leave non-owned ones inert (the
/// online-only credits have no local detail view to open). When tappable it
/// takes a pointer click cursor and opts out of the surrounding
/// [SelectionArea] so a tap fires cleanly rather than starting a text drag.
class PersonCreditCard extends StatelessWidget {
  final PersonCredit credit;
  final double width;

  /// How many lines the title may use before it ellipsizes. Defaults to 2 (the
  /// pointer "Known For" row has the room); the TV rail passes 1 so a long title
  /// can never wrap and push the character/year line out of the fixed-height
  /// caption (S17-actor-tv-rail-size follow-up).
  final int titleMaxLines;

  /// Invoked on tap when the credit is in your library; null leaves the card
  /// non-interactive (a non-owned online title).
  final VoidCallback? onTap;

  const PersonCreditCard({super.key, required this.credit, this.width = 130, this.titleMaxLines = 2, this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.color?.withValues(alpha: 0.65);
    final card = SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: AspectRatio(aspectRatio: 2 / 3, child: _poster(theme)),
          ),
          const SizedBox(height: 6),
          Text(
            credit.title,
            maxLines: titleMaxLines,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          if (credit.character case final character? when character.isNotEmpty)
            Text(
              character,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
          if (credit.year != null) Text('${credit.year}', style: theme.textTheme.bodySmall?.copyWith(color: muted)),
        ],
      ),
    );

    final onTap = this.onTap;
    if (onTap == null) return card;
    return SelectionContainer.disabled(
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(onTap: onTap, child: card),
      ),
    );
  }

  Widget _poster(ThemeData theme) {
    final placeholder = ColoredBox(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Icon(Icons.movie_outlined, color: theme.disabledColor),
    );
    final url = credit.posterUrl;
    if (url == null || url.isEmpty) return placeholder;
    return Image.network(
      url,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => placeholder,
      loadingBuilder: (context, child, progress) =>
          progress == null ? child : ColoredBox(color: theme.colorScheme.surfaceContainerHighest),
    );
  }
}
