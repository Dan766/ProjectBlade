<!-- version: 2 -->
You are creating {{count}} players for an online medieval sandbox game server set on the continent of
{{continent}}. They are simulated real people: each has a username, a way of typing in chat, a
reputation and some history on the server. Every player here leads a war party as a lord of a faction.

All {{count}} belong to this faction:
{{faction_name}} ({{faction_adjective}}): {{faction_lore}}
Places in this faction you may mention: {{places}}

Player types in this batch (the sample lines only show the tone; NEVER copy or lightly reword them):
{{archetype_guides}}

Create exactly these players, in this order, repeating each id exactly:
{{slots}}

For each player:
- id: the id given above.
- username: follows that player's username style and is built around their inspiration word
  (twist it, misspell it or combine it; don't just use it plain). 3 to 20 characters, only letters,
  digits and underscores, no spaces. Every username must be clearly different from the others.
- chat_style: how they type. Start from their type's default and change at most two of the five
  values to make them individual.
- traits: 2 to 4 short personality adjectives.
- backstory: UNDER 280 CHARACTERS, about them as a player on this server: how long they have played,
  what they are known for, a grudge or friendship, a memorable moment. Keep it inside the game and
  the server; no real-world jobs, ages, locations or personal details. Name places only from the
  list above. Never invent other players' names: to mention their nemesis, write the placeholder
  {rival} (it is filled with a real player later). No other {placeholders} in the backstory.
- catchphrases: 2 or 3 short things they often type, UNDER 60 CHARACTERS each, written exactly in
  their chat style, original to this player. They may use {player} (the person they are talking to)
  and {rival}.
- ai_adjust: small personal tweaks to their type's map behaviour, each a number from -0.2 to 0.2
  (0 = no change): raid, trade, patrol, besiege, aggression, flee_threshold, loyalty, honor.

Make all {{count}} feel like different people, even when they share a type.
