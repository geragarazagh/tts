// Passages of the ready voice samples (voices.swift, Clips; Resources/Samples is made from `clip` below by bench/clips):
// every voice reads the same one per language, so voices compare on equal words. Public domain
// everywhere except Bulgakov, below (checked 2026-11-09 against these editions; wording as printed, ё added where the printed
// «е» is a homograph for a voice, typographic apostrophes):
// ru  Ильф и Петров, «Двенадцать стульев», гл. VI (ru.wikisource, ГИХЛ 1961 = ЗиФ 1928 here word for word);
//     Булгаков, «Мастер и Маргарита», гл. 24, Воланд (М.: Высшая школа, 1989, after Худ. лит., 1982; the quote
//     starts at «Никогда», so its first letter is capital). Public domain in Ukraine and the EU; in the US and Russia
//     still claimed by the heirs: kept by the author's decision 2026-11-09, at his own risk.
// uk  Котляревський, «Енеїда», ч. I, строфа 1, перші чотири рядки (ukrlib; «хоть», as in every edition);
//     the pangram of all 33 letters (uk.wikipedia «Панграма», the same in GNOME Pango since 2008).
// en  Shakespeare, As You Like It 2.7 (MIT/Globe text, public domain; Folger's is non-commercial);
//     Dickens, A Tale of Two Cities I.1 (Gutenberg #98), ending at «Darkness».
// Lines of verse are joined by line breaks; the voice reads them as one passage.

enum Samples {
    /// Which passage of each language the bundled clips read: Воланд, Еней, the seven ages (2026-11-10).
    static let clip = ["ru": 1, "uk": 0, "en": 0]
    static let texts: [String: [String]] = [
        "ru": [
            "В продолжение рассказа Остап несколько раз вскакивал и, обращаясь к железной печке, восторженно вскрикивал:\n— Лёд тронулся, господа присяжные заседатели! Лёд тронулся.",
            "Никогда и ничего не просите! Никогда и ничего, и в особенности у тех, кто сильнее вас. Сами предложат и сами всё дадут!",
        ],
        "uk": [
            "Еней був парубок моторний\nІ хлопець хоть куди козак,\nУдавсь на всеє зле проворний,\nЗавзятіший од всіх бурлак.",
            "Чуєш їх, доцю, га? Кумедна ж ти, прощайся без ґольфів!",
        ],
        "en": [
            "All the world’s a stage,\nAnd all the men and women merely players:\nThey have their exits and their entrances;\nAnd one man in his time plays many parts,\nHis acts being seven ages.",
            "It was the best of times, it was the worst of times, it was the age of wisdom, it was the age of foolishness, it was the epoch of belief, it was the epoch of incredulity, it was the season of Light, it was the season of Darkness.",
        ],
    ]
}
