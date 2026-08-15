import Foundation

extension String {
    /// Strips non-ASCII characters from EPG text.
    ///
    /// Providers decorate titles with unicode ornaments — "SportsCenter ᴺᵉʷ" —
    /// which render as tiny superscripts and add noise to an already tight
    /// label. Removing them leaves stray double spaces, so runs of whitespace
    /// are collapsed and trimmed afterwards.
    ///
    /// This also strips accented letters ("Pérez" becomes "Prez"), since they
    /// are equally non-ASCII. Same trade-off as the Dart original.
    var strippedOfNonASCII: String {
        guard !isEmpty else { return self }
        let superscripts: Set<Character> = [
                    "⁰", "¹", "²", "³", "⁴", "⁵", "⁶", "⁷", "⁸", "⁹",
                    "⁺", "⁻", "⁼", "⁽", "⁾", "ᴬ", "ᴮ", "ᴰ", "ᴱ", "ᴳ",
                    "ᴴ", "ᴵ", "ᴶ", "ᴷ", "ᴸ", "ᴹ", "ᴺ", "ᴼ", "ᴾ", "ᴿ",
                    "ᵀ", "ᵁ", "ⱽ", "ᵂ", "ᵃ", "ᵇ", "ᶜ", "ᵈ", "ᵉ", "ᶠ",
                    "ᵍ", "ʰ", "ⁱ", "ʲ", "ᵏ", "ˡ", "ᵐ", "ⁿ", "ᵒ", "ᵖ",
                    "ʳ", "ˢ", "ᵗ", "ᵘ", "ᵛ", "ʷ", "ˣ", "ʸ", "ᶻ"
                ]
                return self.filter { !superscripts.contains($0) }
            }
        }
