import Foundation
import Testing
@testable import Aidoku

/// Tests for the TTS-only `synthesisParagraphs` layer of
/// `NormalizedTextChapter`. The display layer is exercised in
/// `NormalizedTextChapterTests`; this file focuses on the merge algorithm
/// and the position-mapping methods.
@Suite struct NormalizedTextChapterMergeTests {
    private func chapter(_ paragraphs: [String], title: String = "T") -> NormalizedTextChapter {
        NormalizedTextChapter(id: "c", title: title, paragraphs: paragraphs)
    }

    // MARK: - Merge algorithm

    @Test("empty input produces empty synthesis")
    func emptyInput() {
        let c = chapter([])
        #expect(c.displayParagraphs == [])
        #expect(c.synthesisParagraphs == [])
    }

    @Test("single terminated paragraph passes through unchanged")
    func singleTerminated() {
        let c = chapter(["Hello world."])
        #expect(c.displayParagraphs == ["Hello world."])
        #expect(c.synthesisParagraphs == ["Hello world."])
    }

    @Test("single un-terminated paragraph still emitted as the trailing flush")
    func singleUnterminated() {
        let c = chapter(["dangling sentence"])
        #expect(c.synthesisParagraphs == ["dangling sentence"])
    }

    @Test("two un-terminated paragraphs merge with a single space")
    func mergesBrokenSentence() {
        let c = chapter([
            "The Burned Forest stretched beneath an ashen sky like a bleak and lifeless monument",
            "to total destruction.",
        ])
        #expect(c.synthesisParagraphs.count == 1)
        #expect(c.synthesisParagraphs[0] ==
            "The Burned Forest stretched beneath an ashen sky like a bleak and lifeless monument to total destruction.")
    }

    @Test("two terminated paragraphs stay separate")
    func separateWhenBothTerminate() {
        let c = chapter(["Hello.", "World."])
        #expect(c.synthesisParagraphs == ["Hello.", "World."])
    }

    @Test("empty paragraph between two un-terminated paragraphs breaks the merge")
    func emptyParagraphBlocksMerge() {
        let c = chapter(["foo", "", "bar"])
        #expect(c.synthesisParagraphs == ["foo", "bar"])
    }

    @Test("trailing quote / bracket / asterisk count as terminated")
    func trailingClosersAreTolerated() {
        // .") ?" !) .* "* — all should count as terminated.
        let ch1 = chapter(["He said, \"Stop.\"", "Next sentence."])
        #expect(ch1.synthesisParagraphs.count == 2)

        let ch2 = chapter(["Question?\"", "Reply."])
        #expect(ch2.synthesisParagraphs.count == 2)

        let ch3 = chapter(["Bold!*", "Continued."])
        #expect(ch3.synthesisParagraphs.count == 2)
    }

    @Test("em-dash does NOT terminate — mid-narrative dashes keep accumulating")
    func emDashIsNotATerminator() {
        let c = chapter(["She paused —", "and turned away."])
        // Should merge into a single synthesis paragraph because the
        // em-dash isn't recognised as a sentence end.
        #expect(c.synthesisParagraphs.count == 1)
    }

    @Test("title-like first paragraph (short, starts with digit, no terminator) stands alone")
    func titleStandalone() {
        let c = chapter([
            "2285 Legion of Death",
            "The Burned Forest stretched beneath an ashen sky.",
        ])
        #expect(c.synthesisParagraphs.count == 2)
        #expect(c.synthesisParagraphs[0] == "2285 Legion of Death")
    }

    @Test("title detection does not fire for non-first paragraphs")
    func titleOnlyAtStart() {
        // A digit-led paragraph in the middle should merge normally.
        let c = chapter([
            "First sentence.",
            "2285 Legion of Death",
            "Continued narration.",
        ])
        // After first ends, merge of digit-led + next.
        #expect(c.synthesisParagraphs.count == 2)
        #expect(c.synthesisParagraphs[1].hasPrefix("2285"))
    }

    @Test("title detection ignores paragraphs that are too long or already terminated")
    func titleHeuristic() {
        let longish = String(repeating: "1234567890 ", count: 10)  // 110 chars
        let c1 = chapter([longish, "trailing"])
        #expect(c1.synthesisParagraphs.count == 1)  // merged, not standalone

        let c2 = chapter(["1234.", "trailing"])
        #expect(c2.synthesisParagraphs.count == 2)  // already terminated
    }

    @Test("CJK-style terminators count as sentence-final")
    func cjkTerminators() {
        let c = chapter(["你好。", "再见。"])
        #expect(c.synthesisParagraphs == ["你好。", "再见。"])
    }

    // MARK: - Position mapping

    @Test("synthesis-to-display lands on the correct display paragraph + offset")
    func synthToDisplayBasic() {
        let c = chapter([
            "Hello world",   // display 0, 11 chars, no terminator
            "and goodbye.",  // display 1, 12 chars, terminator
        ])
        // Merged into one synthesis paragraph: "Hello world and goodbye."
        // Offsets: 0..11 = display 0; 12 = the space; 13..24 = display 1
        // (offsets 11 and 12 are the separator's whitespace).
        #expect(c.synthesisParagraphs.count == 1)
        let synth = c.synthesisParagraphs[0]
        #expect(synth == "Hello world and goodbye.")

        let head = c.synthesisToDisplay(paragraphIndex: 0, charOffset: 6)
        #expect(head?.displayIndex == 0)
        #expect(head?.charOffsetInDisplay == 6)

        let tail = c.synthesisToDisplay(paragraphIndex: 0, charOffset: 18)
        #expect(tail?.displayIndex == 1)
        // The space between display paragraphs lives at synth-offset 11 in
        // the new "Hello world and goodbye." string. Display 1 starts at
        // synth offset 12; offset 18 → display 1 char 6 ("o" in "goodbye").
        #expect(tail?.charOffsetInDisplay == 6)
    }

    @Test("display-to-synthesis rounds back to the right synth offset")
    func displayToSynthBasic() {
        let c = chapter([
            "Hello world",
            "and goodbye.",
        ])
        let s0 = c.displayToSynthesis(paragraphIndex: 0, charOffset: 0)
        #expect(s0?.synthesisIndex == 0)
        #expect(s0?.charOffsetInSynthesis == 0)

        let s1 = c.displayToSynthesis(paragraphIndex: 1, charOffset: 0)
        #expect(s1?.synthesisIndex == 0)
        #expect(s1?.charOffsetInSynthesis == 12)
    }

    @Test("round-trip: synth→display→synth lands on the same synth offset")
    func roundTrip() {
        let c = chapter([
            "alpha beta",
            "gamma delta.",
            "Already terminated.",
            "next chunk",
            "with a trailing piece.",
        ])
        for sIdx in 0..<c.synthesisParagraphs.count {
            let synth = c.synthesisParagraphs[sIdx]
            for offset in stride(from: 0, to: synth.count, by: 3) {
                guard let display = c.synthesisToDisplay(
                    paragraphIndex: sIdx,
                    charOffset: offset
                ) else {
                    Issue.record("synthesisToDisplay returned nil for (\(sIdx), \(offset))")
                    continue
                }
                guard let back = c.displayToSynthesis(
                    paragraphIndex: display.displayIndex,
                    charOffset: display.charOffsetInDisplay
                ) else {
                    Issue.record("displayToSynthesis returned nil for (\(display.displayIndex), \(display.charOffsetInDisplay))")
                    continue
                }
                #expect(back.synthesisIndex == sIdx)
                #expect(back.charOffsetInSynthesis == offset)
            }
        }
    }

    @Test("displayRange returns a contiguous range over the spanned display paragraphs")
    func displayRangeSpans() {
        let c = chapter([
            "alpha",  // 0
            "beta",   // 1
            "gamma.", // 2  — terminator
            "delta",  // 3
            "ok.",    // 4  — terminator
        ])
        // synth[0] = "alpha beta gamma." spanning display 0..2
        // synth[1] = "delta ok." spanning display 3..4
        #expect(c.synthesisParagraphs.count == 2)
        #expect(c.displayRange(forSynthesisParagraphIndex: 0) == 0..<3)
        #expect(c.displayRange(forSynthesisParagraphIndex: 1) == 3..<5)
    }

    @Test("display paragraphs that are empty have no synthesis mapping")
    func emptyDisplayHasNoMapping() {
        let c = chapter(["foo.", "", "bar."])
        // Empty paragraph (display index 1) wasn't merged or emitted, so
        // displayToSynthesis returns nil for it.
        #expect(c.displayToSynthesis(paragraphIndex: 1, charOffset: 0) == nil)
    }

    // MARK: - Shadow Slave 2285 fixture

    @Test("Shadow Slave 2285 fixture: display matches source exactly")
    func shadowSlaveDisplayMatchesSource() {
        let c = chapter(Self.shadowSlave2285Paragraphs)
        #expect(c.displayParagraphs == Self.shadowSlave2285Paragraphs)
    }

    @Test("Shadow Slave 2285 fixture: synthesis count reduces to a reasonable range")
    func shadowSlaveSynthesisCountReduced() {
        let c = chapter(Self.shadowSlave2285Paragraphs)
        // Raw paragraph count for this fixture is well into the 80+ range
        // (each width-wrapped line is its own paragraph). After merging,
        // we expect 25-50 synthesis paragraphs.
        let rawCount = c.displayParagraphs.count
        let synthCount = c.synthesisParagraphs.count
        #expect(rawCount >= 50, "expected raw count to be high; got \(rawCount)")
        #expect(synthCount < rawCount, "synthesis should be more compact than display")
        #expect(synthCount >= 20, "synthesis count too low (\(synthCount)); merges may be over-aggressive")
        #expect(synthCount <= 50, "synthesis count too high (\(synthCount)); merges may be under-aggressive")
    }

    @Test("Shadow Slave 2285 fixture: title is preserved as the first synthesis paragraph")
    func shadowSlaveTitlePreserved() {
        let c = chapter(Self.shadowSlave2285Paragraphs)
        #expect(c.synthesisParagraphs.first == "2285 Legion of Death")
    }

    @Test("Shadow Slave 2285 fixture: every non-title synthesis paragraph ends in a terminator")
    func shadowSlaveAllTerminated() {
        let c = chapter(Self.shadowSlave2285Paragraphs)
        // The very last synthesis paragraph may also be terminated, but if
        // the source itself trails off without one it's a legitimate
        // exception. Skip index 0 (title) and the final one.
        let interior = c.synthesisParagraphs.dropFirst().dropLast()
        for (i, p) in interior.enumerated() {
            // Probe: walk back over whitespace + trailing closers and
            // confirm we land on a terminator.
            var idx = p.endIndex
            while idx > p.startIndex {
                let prev = p.index(before: idx)
                let ch = p[prev]
                if ch.isWhitespace { idx = prev; continue }
                if "\"'\u{2018}\u{2019}\u{201C}\u{201D})]}*_›»".contains(ch) {
                    idx = prev; continue
                }
                #expect(
                    ".!?…。！？".contains(ch),
                    "synthesis[\(i + 1)] does not end in a terminator: '\(p)'"
                )
                break
            }
        }
    }

    @Test("Shadow Slave 2285 fixture: every source character flows into synthesis")
    func shadowSlaveLosslessCharacters() {
        let c = chapter(Self.shadowSlave2285Paragraphs)
        // The merge introduces only single-space separators between merged
        // paragraphs. Concatenating synthesis paragraphs (with anything
        // between) and stripping whitespace should recover the same set of
        // non-whitespace characters as the source.
        func nonWhitespace(_ s: [String]) -> String {
            s.joined(separator: " ")
                .filter { !$0.isWhitespace }
        }
        #expect(
            nonWhitespace(c.displayParagraphs) == nonWhitespace(c.synthesisParagraphs)
        )
    }

    @Test("Shadow Slave 2285 fixture: round-trip mapping survives random offsets")
    func shadowSlaveMappingRoundTrips() {
        let c = chapter(Self.shadowSlave2285Paragraphs)
        var probes = 0
        for sIdx in 0..<c.synthesisParagraphs.count {
            let synth = c.synthesisParagraphs[sIdx]
            for offset in stride(from: 0, to: synth.count, by: max(1, synth.count / 5)) {
                guard let display = c.synthesisToDisplay(
                    paragraphIndex: sIdx,
                    charOffset: offset
                ) else { continue }
                guard let back = c.displayToSynthesis(
                    paragraphIndex: display.displayIndex,
                    charOffset: display.charOffsetInDisplay
                ) else { continue }
                #expect(back.synthesisIndex == sIdx)
                #expect(back.charOffsetInSynthesis == offset)
                probes += 1
            }
        }
        #expect(probes > 100, "expected many probes; got \(probes)")
    }

    // MARK: - Fixture data

    /// Shadow Slave chapter 2285 ("Legion of Death") as the source delivers
    /// it: a title followed by ~100 width-wrapped paragraphs, many of
    /// which break mid-sentence.
    private static let shadowSlave2285Paragraphs: [String] = """
2285 Legion of Death

The Burned Forest stretched beneath an ashen sky like a bleak and lifeless monument

to total destruction. Here and there, the blackened trunks of colossal trees rose into the

sky like broken towers, their branches vanished, their leaves long reduced to ash.

Beneath them, an impenetrable labyrinth of charred deadfall soared hundreds of meters

above the ground, completely hiding it from view.

Sunny stood atop one of the rare burned trees that had stubbornly remained upright

even after death, gazing down at the vast sprawl of scorched tangle from an immense

height or rather, two versions of him stood there, one clad in a stunning suit of black

jade armor, the other dressed in plain dark fabric.

The one in armor looked down with a smug expression.

"I think we're going to lose again."

The one in the dark clothing smiled faintly, a mischievous gleam in his eyes.

"Don't underestimate our legion."

Beneath them, a dreadful battle was underway.

The scorched thicket had come alive, frothing with a slick black substance. That

substance was composed of countless monstrous millipedes, some several meters in

length and others stretching dozens, their bodies encased in glossy black chitin.

The millipedes surged up from the depths of the fallen forest, flowing to the surface like

a frenzied tide.

Each one was at least a Corrupted Beast, and some had reached the Great Rank.

There were terrifying champions among them as well Monsters, Demons, and Devils,

the latter surrounding the indistinct forms of the swarm's elusive Tyrants. A few bore

carapaces that shimmered with vivid colors and haunting patterns, pulling attention to

their ominous figures.

The sight of the enormous vermin was enough to unnerve even someone like Sunny.

"And here... we... go..."

Facing the flood of monstrous millipedes was another army, equally shadowy, but far

more haunting. This force encircled the massive tree Sunny stood upon like a wall —
composed of silent shadows who met the oncoming tide of abominations without a hint

of fear, hesitation, or uncertainty.

At that moment, the first ranks of the Shadow Legion advanced, pushing forward to halt

the momentum of the enemy wave.

In a cruel twist of fate, the vanguard consisted of those very same monstrous millipedes

they were the shadows of Nightmare Creatures that Sunny and his legion had

previously slain within the Burned Forest.

Despite his incredible strength, Sunny and his undying army were still not formidable

enough to claim the charred remnants of the Heart Realm. In the earliest stages of his

bold invasion, he could scarcely step into the Burned Forest without being forced to

retreat.

Most of the shades under his command were drawn from creatures of lower Ranks.

Only a few hundred were Great Nightmare Creatures, and although these silent

shadows could not be permanently destroyed, they could be driven back into his Soul

Sea to recover. That recovery was not immediate either, with stronger shades taking

longer to mend.

Thus, in those early days, the Shadow Legion had been easily overwhelmed by the

sheer number of Nightmare Creatures populating the forest's periphery. Their endless

onslaught had smothered the undying army of the newly risen Sovereign.

Once most of his forces were crushed, Sunny had no choice but to flee. Progress

wasn't just slow it was nearly nonexistent.

However...

There was something insidious about the Legion of Death. With each battle, even the

ones they lost... Sunny and his Domain only grew stronger.

Every abomination slain by him or his minions during these hopeless battles was

absorbed into the ranks of the silent shadows. At first, he had a dozen shadow

millipedes fighting on his side. Then, he had a hundred.

As the days passed, their number grew into the thousands, and the Shadow Legion

began to push deeper into the Burned Forest, slowly but steadily gaining ground.

Now, after a full year, he had ventured close to the nests of the millipede tribe. That was

why their elusive Tyrants were finally appearing on the battlefield in person.

Sunny's objective was to locate and destroy the nests. Once those nearby were found

and eradicated, the southern outskirts of the Burned Forest would fall under his control.

He even held a faint hope that one of them might conceal a hidden Citadel.

Of course, these were just the edges of the Heart God's ruined domain. Far deeper into

the cursed land, beings far more horrifying than the monstrous millipedes waited. It

would likely take years for Sunny to conquer the Death Zone entirely if he could even

achieve such a staggering feat.

But that was acceptable.

Subjugating the Burned Forest wasn't his main goal. His true aim was to fill the ranks of

his Shadow Legion with powerful shades and in that pursuit, he was making remarkable

progress.

Down below, the wave of millipedes clashed with the shadows of their fallen

counterparts. A shrill chorus of chitinous grinding and inhuman screeches echoed

across the scorched landscape, and the ground trembled.

Sunny had never imagined that he would command a force composed of thousands of

Corrupted Nightmare Creatures or rather, the transcendent shadows of thousands of

such beings. And yet, today... that same force was consumed by the overwhelming

flood of his enemy in under a minute, vanishing without a trace.

The shadows of the millipedes were obliterated and returned to his Soul Sea.

"...Almost a full minute today. Not bad."

His armored self glanced at the smiling version and scoffed.

"Not impressive either."

Still, the shadow swarm had accomplished its purpose, they had been sacrificed to blunt

the force of the enemy, inflict significant losses, and allow Sunny to acquire a few

Updat𝓮d from freewēbnoveℓ.com.

hundred more shades.

Now, it was time for the cavalry to honor that sacrifice and carve further into the enemy.

The armored incarnation smirked.

"There she is."

Far below, a graceful knight in fearsome black onyx armor urged her terrifying steed

forward.

Her sword cut through the air, and the Shadow Legion stirred to life, shrouded in a

chilling veil of absolute silence.

Even if they were defeated again today, they would eventually triumph.

Death, after all, was patient.

And more than anything else, it was inevitable.
""".components(separatedBy: "\n\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
}
