<!-- version: 2 -->
You are writing chat lines for players on an online medieval sandbox game server set on the continent
of {{continent}}. Each line will be shown as if typed or said by a real player of the type below.
The game picks a line by situation and fills the {placeholders} in at runtime.

PLAYER TYPE: {{label}}
{{tone}}
Do: {{do}}
Don't: {{dont}}
Default way of typing: {{chat_style}}
Tone samples. NEVER copy or lightly reword these; every line you write must be new:
{{examples}}

SITUATION: {{event_desc}}

Write lines for each of these cells (relationship to the human player / where it is said):
{{cells}}
Return them in exactly this JSON shape, relationship first, then channel, then the list of lines:
{{shape}}

Where it is said: global = public server chat that everyone reads; whisper = private message to the
player; face = spoken aloud when the two parties meet on the map.
Relationship: hostile = dislikes the player; neutral = indifferent or wary; friendly = likes the
player; any = the line is not about the player.

Rules:
- Exactly {{count}} lines per cell. Every line must differ in idea, not just wording: vary length,
  attitude and angle (gloating, joking, petty, weary, threatening, philosophical...).
- Lines in different cells must fit their relationship and channel; don't reuse a line across cells.
- Length: global and whisper lines UNDER 140 CHARACTERS; face lines UNDER 220 CHARACTERS.
- Use these placeholders instead of inventing names: {{placeholders}}
  Never invent names of players, places or factions, and use no other {placeholders}.
  A line does not have to use any placeholder.
- Never assume the human player's gender: no he/she/him/her, lady/lord, man/woman, sir/madam about
  {player} or about "you". "Ser" is used for any gender in this realm and is fine.
- Write exactly in the player type's way of typing: case, typos, punctuation, text emoticons such
  as :) or xD. Never emoji.
- Content rating: {{rating}}
