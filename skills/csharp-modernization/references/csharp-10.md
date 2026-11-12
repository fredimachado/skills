# C# 10

The SDK-style default for `net6.0`. The examples use C# 10 syntax.

## Global usings and file-scoped namespaces

```csharp
global using System.Collections.Generic;

namespace App.Model;

public readonly record struct Size(int Width, int Height);
```

- A `global using` is visible in every file in the compilation. Put it before ordinary usings in its file. Keep imports used by one file local. Check aliases and extension method resolution before widening the scope of a using. SDK-generated implicit usings come from the `ImplicitUsings` project setting and vary by SDK. Inspect generated usings before removing explicit imports.
- Convert a block namespace when the file has one namespace and no incompatible top-level declarations. Preserve the scope of imports during the edit. In `namespace N;` form, a using after the declaration is inside `N`, and a using before it is outside. [Welcome to C# 10](https://devblogs.microsoft.com/dotnet/welcome-to-csharp-10/)

## Record structs, `with`, and struct constructors

- Use a `record struct` for small value types when generated value equality, hashing, and deconstruction match the API. Positional properties of `record struct` are read-write. `readonly record struct` gives positional `init` properties. Changing a class to a struct also changes copying, nullability, boxing, identity, and default values.
- `with` on a struct copies the value and applies assignments to the copy. `with` on an anonymous type constructs a new instance with the updated properties. Copies of reference members still share their referenced objects. A record class can `sealed override` `ToString()` to prevent generated derived overrides.
- A struct can declare a public parameterless instance constructor and instance member initializers. `new S()` invokes the constructor, while `default(S)` and a new `S[]` zero-initialize. A struct with instance field initializers needs an explicitly declared constructor. C# 10 constructors must satisfy definite assignment, with [C# 11 auto-default](csharp-11.md) relaxing that rule. [Record struct and constructor proposals](https://github.com/dotnet/csharplang/tree/main/proposals/csharp-10.0)

## Lambdas and method groups

```csharp
public static class Delegates
{
    public static int ReadLength(string text)
    {
        var count = (string value) => value.Length;
        var parse = int (string value) => int.Parse(value);
        return count(text) + parse(text);
    }
}
```

- A lambda with enough type information can have a natural delegate type. A method group can also have a natural type when the compiler can determine a suitable signature. A lambda with untyped parameters still needs a target. Use an explicit delegate where overload selection, expression-tree conversion, or the public contract matters.
- Give a lambda an explicit return type where needed, as in `object (bool yes) => yes ? 1 : "no"`. Lambda attributes are supported on the lambda, parameters, and return value. Use parentheses on an attributed lambda's parameter list and keep attribute targets accurate. Attributes do not become part of the delegate's signature. [Lambda improvements proposal](https://github.com/dotnet/csharplang/blob/main/proposals/csharp-10.0/lambda-improvements.md)

## Patterns, deconstruction, and constants

- Use `{ Address.City: "Oslo" }` in place of `{ Address: { City: "Oslo" } }` when the shorter extended property pattern reads better. Intermediate nulls make the nested match fail. Preserve any guard logic when changing existing member access to a pattern.
- A deconstruction can mix new variables and existing targets, as in `(existing, int added) = (1, 2);`. Verify the selected `Deconstruct` and any side effects from assignment targets.
- `const string Label = $"{Prefix} id";` works when `Prefix` is a constant string. Numeric or formatted interpolation generally needs runtime formatting. Keep values that depend on culture or formatting out of constant interpolations.
- Improved definite assignment and null-state analysis recognize more conditional-access and boolean flows. A newer compiler may make an old workaround redundant. Rebuild before removing the workaround and keep runtime guards where they enforce an invariant. [C# version history](https://learn.microsoft.com/en-us/dotnet/csharp/whats-new/csharp-version-history#c-version-10)

## Interpolated string handlers, caller expressions, and tooling

- An interpolated string can bind to a custom handler annotated with `InterpolatedStringHandlerAttribute`. A handler constructor with an `out bool`, or append methods returning `bool`, can suppress later interpolation work. Check whether interpolation expressions were previously always evaluated and whether a new overload changes formatting, culture, exceptions, or argument binding. Use an explicit `string` when eager formatting is part of the contract. [Interpolated string handler tutorial](https://learn.microsoft.com/en-us/dotnet/csharp/advanced-topics/performance/interpolated-string-handler)
- `[CallerArgumentExpression(nameof(value))] string? expression = null` captures source text for an argument when the optional argument is omitted. It is useful for assertion and guard APIs. Changing an existing public signature can break binary callers. Check the API shape and avoid exposing sensitive source text through logging. [Caller information attributes](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/attributes/caller-information)
- Apply `AsyncMethodBuilderAttribute` to an individual async method for a deliberate builder choice. Verify the builder contract and compatible return type, and measure the allocation or pooling benefit before changing it.
- The enhanced `#line (startLine, startColumn) - (endLine, endColumn) characterOffset "file"` directive maps generated spans back to original sources. Treat it as generator tooling and verify mapped diagnostics and debugger locations. [C# 10 proposals](https://github.com/dotnet/csharplang/tree/main/proposals/csharp-10.0)
