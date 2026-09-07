// Editorial facts checked 2026-09-06. Keep a supporting source on every card.
// The Heidi origin story is a popular explanation, not a proven causal history.
export interface Story { title: string; text: string; source: string; url: string }
const story = (title: string, text: string, source: string, url: string): Story => ({ title, text, source, url });
const heidi = 'https://www.fami-geki.com/heidi/special.html';
const black = 'https://blackbutler-anime.com/introduction/';
const overlord = 'https://overlord-anime.com/_season2/character/';
const hayate = 'https://hatakenjirou.com/hayate/';
const nature = 'https://www.takao599museum.jp/treasures/?lang=en';
const crests = 'https://www.nippon.com/en/japan-data/h01578/';
const cafe = 'https://www.tsunagujapan.com/butlers-cafe-swallowtail/';
const guide = 'https://www.butlers-cafe.jp/swallowtail/guidance_en';
const coat = 'https://kotobank.jp/word/燕尾服-38355';

export const mascotStories = {
  anime: {
    label: 'Butlers in anime',
    stories: [
      story('Why so many Sebastians?', 'You have spotted a real convention, though it is not a rule! A popular explanation traces it to Sebastian in the 1974 anime Heidi, Girl of the Alps. Fans often cite that earlier household servant when discussing later butlers. Treat the connection as a theory, not a documented origin for every character.', 'Anime & Manga Stack Exchange: discussion of the trope', 'https://anime.stackexchange.com/questions/3527/are-a-lot-of-butlers-named-sebastian'),
      story('Meet the earlier Sebastian', 'Heidi’s Sebastian serves the Sesemann household and looks after Clara. The broadcaster’s character guide describes a kind man who quietly helps Heidi despite the strict Rottenmeier. This Sebastian is remembered for kindness rather than supernatural competence.', 'Family Gekijo: Heidi character guide (Japanese)', heidi),
      story('A helpful supporting character', 'A small detail worth watching for: the Heidi guide points to episode 34 for Sebastian accompanying Heidi on her journey. His role is practical care and companionship. A butler-like character can shape a story without being its hero.', 'Family Gekijo: Heidi character guide (Japanese)', heidi),
      story('The household has several roles', 'In Heidi, Sebastian and Rottenmeier are different people with different responsibilities. The guide presents him as a servant caring for Clara and her as the strict figure overseeing the household. Calling everyone in a fictional household “the butler” can flatten those distinctions.', 'Family Gekijo: Heidi character guide (Japanese)', heidi),
      story('Sebastian in Black Butler', 'Black Butler places Sebastian in the aristocratic Phantomhive household. Its official introduction stresses his exceptional ability to carry out his young master’s requests. That polished surface is part of the series’ appeal: impeccable service belongs inside a much darker story.', 'Black Butler: official introduction', black),
      story('A Japanese story of England', 'The official Black Butler introduction sets the story in nineteenth-century Britain. It is a useful distinction: a butler in Japanese manga need not depict a historical Japanese occupation. The setting and its aristocratic household are part of the fiction.', 'Black Butler: official introduction', black),
      story('Sebas has a second half', 'Overlord’s official Japanese character page writes its butler’s name as セバス・チャン. Put the two parts together and you can hear “Sebastian.” The wordplay is visible in the spelling; the page does not establish why the author chose it.', 'Overlord: official character guide (Japanese)', overlord),
      story('More than serving tea', 'Overlord’s Sebas commands the Pleiades combat maids. His official profile also emphasizes his concern for protecting the weak. The composed servant and formidable fighter coexist in one character, showing how far a fantasy butler can range beyond domestic work.', 'Overlord: official character guide (Japanese)', overlord),
      story('Not every butler is Sebastian', 'Hayate Ayasaki is a clear counterexample. Creator Kenjiro Hata’s own series page identifies Hayate as the boy Nagi appoints as her butler after he saves her. “Sebastian” is a recognizable convention, not a naming requirement.', 'Kenjiro Hata: Hayate the Combat Butler (Japanese)', hayate),
      story('The job can begin with a misunderstanding', 'Hayate’s creator describes Nagi misunderstanding his feelings before appointing him as her butler. That setup makes the household job a source of comedy and relationships. It offers a very different starting point from an already-perfect, mysterious servant.', 'Kenjiro Hata: Hayate the Combat Butler (Japanese)', hayate),
    ],
  },
  nature: {
    label: 'Swallowtails & Japanese crests',
    stories: [
      story('A swallowtail in the garden', 'Papilio xuthus, the Asian swallowtail, lives across much of Japan. Takao’s museum notes that its caterpillars’ food plants grow in gardens and hedges, bringing this butterfly into residential neighborhoods.', 'Takao 599 Museum: insect guide', nature),
      story('Follow the black lines', 'The Asian swallowtail’s pale wings carry intricate black veins, with blue and red markings near the lower hindwings. A familiar butterfly rewards a closer look.', 'Takao 599 Museum: insect guide', nature),
      story('Two yellows, two diets', 'The similar-looking kiageha, Papilio machaon, is more strongly yellow. Its caterpillars eat plants in the parsley family; Asian swallowtail caterpillars use the citrus family.', 'Takao 599 Museum: insect guide', nature),
      story('Color that changes with your viewpoint', 'Papilio bianor has dark wings covered in blue-green scales. Their apparent brightness changes with viewing angle. A black silhouette alone misses the colors of this Japanese woodland butterfly.', 'Takao 599 Museum: insect guide', nature),
      story('Butterflies on the mountain trail', 'Takao’s guide notes male Papilio bianor drinking water along mountain trails. It also describes swallowtail males repeatedly flying regular routes. Watch where they return.', 'Takao 599 Museum: insect guide', nature),
      story('A butterfly at high altitude', 'Papilio machaon is found from lowlands to elevations around 3,000 meters. Males may hold territory near summits. Japan’s swallowtails are not confined to garden flowers.', 'Takao 599 Museum: insect guide', nature),
      story('The butterfly as a family emblem', 'Japanese heraldry includes a Taira-associated butterfly design called yoroi agehachō, translated as “armored swallowtail butterfly.” It is a stylized emblem, not a scientific drawing. The heraldry database cites published crest references for the design.', 'Japanese Heraldry Database: Taira Butterfly', 'https://mon.xavid.us/Mon/Taira%20Butterfly'),
      story('Before logos, there were kamon', 'Japanese family crests, or kamon, are thought to have emerged among aristocrats around the tenth century. Crests on ox-drawn carriages identified status. Later, these compact marks appeared on clothing and spread beyond the nobility.', 'Nippon.com: Japan’s family crests', crests),
      story('A crest is not only a samurai symbol', 'Kamon also became part of merchant and theatrical life. Nippon.com describes merchants using crests on shop signs and kabuki actors adopting them. A butterfly emblem belongs within a much wider history of visual identification.', 'Nippon.com: Japan’s family crests', crests),
      story('One motif, many variations', 'There is no single universal Japanese family crest system with one fixed drawing per motif. Altered personal crests and women’s crests added further variations. When researching a butterfly mon, look for the specific design and family rather than assuming every butterfly means the same thing.', 'Nippon.com: Japan’s family crests', crests),
    ],
  },
  culture: {
    label: 'Cafés, tailoring & Japan',
    stories: [
      story('A real Swallowtail in Ikebukuro', 'Tokyo has a butler café named Swallowtail, opened in Ikebukuro in 2006. A reported visit describes a Victorian-inspired tea salon. Here, the butler idea becomes a hospitality performance you can step into, rather than only a character on a screen.', 'tsunagu Japan: reported café visit, 2024', cafe),
      story('A different audience for the concept café', 'According to tsunagu Japan’s account, K-BOOKS researched a concept café aimed at women before establishing Swallowtail on Otome Road. Its setting offered a different fantasy from the maid cafés associated with Akihabara.', 'tsunagu Japan: reported café visit, 2024', cafe),
      story('The performance includes real study', 'The café’s staff told visiting reporters that training includes polite Japanese, posture, movement, tea, and tea ware. Candidates are tested before welcoming guests. The costume is only one part of a practiced service role.', 'tsunagu Japan: staff interview, 2024', cafe),
      story('A butterfly at the bottom of the cup', 'The 2024 café report describes a golden swallowtail butterfly inside its original teacup. It is a small visual reward as the tea disappears: the name becomes part of the table setting.', 'tsunagu Japan: reported café visit, 2024', cafe),
      story('The guest does not need a costume', 'Swallowtail’s visitor guidance says guests may wear casual clothes. The staff’s formal presentation does not require visitors to arrive dressed as aristocrats. The imagined household comes from the welcome and service, not a compulsory guest costume.', 'Swallowtail café: visitor guidance', guide),
      story('The welcome has a sequence', 'The café describes a doorman confirming reservations, followed by butlers greeting each group. Even arrival has a staged rhythm. That sequence helps establish the household setting before a guest reaches the table.', 'Swallowtail café: visitor guidance', guide),
      story('What does enbifuku mean?', 'The Japanese word 燕尾服, enbifuku, refers to a tailcoat. Its name evokes a swallow’s forked tail through the divided coat skirts. That is the bird-shaped tailoring connection behind the word, distinct from a butterfly’s Japanese name.', 'Kotobank: Japanese dictionary entries for enbifuku', coat),
      story('Tailcoats in Meiji Japan', 'The encyclopedia entries for enbifuku note that Japan’s 1872 dress regulations designated this Western-style coat as men’s principal formal court attire. Its Japanese history therefore reaches beyond modern café uniforms and manga wardrobes.', 'Kotobank: history of enbifuku', coat),
      story('Formal dress has a time of day', 'Japanese tailoring references classify the tailcoat as formal evening wear. A tuxedo and a tailcoat are not interchangeable names for the same garment. The long, divided back of the tailcoat is its most visible clue.', 'Ginza Eikokuya: tailcoat guide (Japanese)', 'https://www.eikokuya.co.jp/customsuit/customsuit-column/howto-wear-tailcoat/'),
      story('A bow tie can tell you the dress code', 'A Japanese tailoring glossary distinguishes white tie with a tailcoat from black tie with a tuxedo. This mascot’s mulberry bow is a character-design choice, rather than a demonstration of either formal dress code.', 'Pitty Savile Row: swallow-tail glossary (Japanese)', 'https://www.order-suits.com/design/fashion_term/03sa/3su/swallow_tail.html'),
    ],
  },
};
export type StoryTopic = keyof typeof mascotStories;
