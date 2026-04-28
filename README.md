# Ezcaper

A simple library for escaping strings and codepoints in format printing.

## Purpose

Debugging and logging, among other uses, often want to print a string in the style of a source-code string.  Zig has [std.zig.stringEscape](https://ziglang.org/documentation/master/std/#std.zig.stringEscape), but this escapes all non-ASCII input using `\xXX`-style escape sequences, which is valid Zig, but not ideal for seeing what a multi-byte string actually consists of.

The `ezcaper` library has several functions which serve to print strings, and codepoints, in a way which is valid Zig source code, but more legible, more like one might write the string naturally.

## Install

```sh
zig fetch --save https://github.com/mnemnion/ezcaper/archive/refs/tags/v0.3.2.tar.gz
```

## Design


The brains of the operation is the oddly-specific function `whichControlKind`, which answers with the enums `.control`, `.format`, and `.normal`.  This allows for strings and codepoints to have different behavior for format characters: escaped as codepoints and printed directly as strings.  This lets Farmer Bob "👨🏻‍🌾" print as a single grapheme, while the ZWJ in Farmer Bob, in isolation, becomes `'\u{200d}'`.

There's also the simpler `isControl`, which converts `.control` and `.format` to `true` and `.normal` to `false`.  Both of these are public functions, on the off chance that one might find them independently useful.

The functions are code-generated from the Unicode Character Database data for version 16.0, and will be updated upon the occasion of subsequent versions of Unicode.  It uses a master switch to separate codepoints by power-of-two, which generates superior object code to a single ginormous switch, but is likely somewhat less efficient than the lookup table employed by `zg`.  With the compensating advantage that it's pure code with no allocations.

These are used to power a few structs, intended to be used in formatted printing. `EscChar` and `EscCharQuoted` will print a single `u21`.  `EscChar` will print the character 'bare', `EscCharQuoted` will surround it with a pair of quotes and write `'` as `\'`.  This will throw an error if the codepoint is too large; since the `0.15` error set is no longer inferred, that error will be `WriteFailed`, instead of the original `CodepointTooLarge`.  Sorry.

There are four structs for printing escaped strings: `EscStringExact` and `EscStringLossy`, and their `-Quoted` variants. `EscStringExact` will print `\x` codes for any invalid Unicode data, while `EscStringLossy` will print the Unicode Replacement Character `U+FFFD` for any invalid sequences, following the recommended approach to substitution in the Unicode Standard.

The "not `Quoted`" pair will print the string without quotes, while the other two will print the string in double-quotes, and escape a double quote as `\"` and a backslash as `\\`.  Both use the escape sequences `\t`, `\r`, and `\n`, print ASCII C0 codes as `\xXX`, and all other escaped values in the `\u{XXXX}` format.

It is a bug if the string produced by `EscStringExact(Quoted)` does not read into Zig with a byte-identical result to the source string.  It is *not* a bug if `zig fmt` formats the result string differently from `ezcaper`.

Note that `EscChar` will escape surrogate codepoints, which is not (currently) valid in Zig source code.  The string printers will replace or byte-print surrogates, respectively, and this will change if and when escaped surrogates become valid in Zig strings, see issue [#20270](https://github.com/ziglang/zig/issues/20270).

For convenient formatting, these structs can be created with helper functions `escChar`, `escStringExact`, and `escStringLossy`, all of which, you guessed it, have `Quoted` variants[^1].  Example use:

```zig
std.debug.print("a string: {} and a char {u}", .{escStringExact(str), escChar(c)});
```

The mnemonic here is that `{s}` and `{u}` do the same thing which the standard library does, and `{}` does the fancier custom thing.


## Plans

I don't expect changes to this library at any point, other than to update the generated code each time Unicode releases a new standard.  If you see output which looks like a bug, and I agree, I'll fix that.

This module has [runerip](https://github.com/mnemnion/runeset) as a dependency, because the API makes handling both kinds of string print easier.  This dependency may be removed at some future point.

[^1]: This was perhaps the only library in existence which was using the now-removed format strings for `.format` printing. If that [changes further](https://github.com/ziglang/zig/issues/25358), however unlikely that may seem, the interface will change again to match it.
