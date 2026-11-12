# C# 11

The SDK-style default for `net7.0`. The examples use C# 11 syntax.

## Raw strings, UTF-8 literals, and interpolation

```csharp
public static class Payloads
{
    public static string Example() => """
        { "path": "C:\\data" }
        """;

    public static System.ReadOnlySpan<byte> HeaderName() => "Content-Type"u8;
}
```

- Raw strings use a delimiter of three or more quotes. Increase the delimiter length to exceed the longest consecutive quote run in the content. For multiline literals, the closing delimiter sets the indentation removed from content. Check exact output, including backslashes, whitespace, and line endings, when converting JSON, SQL, or snapshots.
- With `$$"""`, `{{expression}}` interpolates and a single brace is literal. Pick the number of `$` characters based on the braces in the content. Multiline expressions are allowed inside interpolation holes, including in ordinary interpolated strings. JSON interpolation still needs escaping for dynamic values, so use a serializer for untrusted or arbitrary strings.
- A `u8` string literal produces UTF-8 bytes as `ReadOnlySpan<byte>`. The span's length excludes the compiler-provided trailing zero. This fits byte-oriented APIs. `u8` cannot be applied to an interpolated string or a `string` variable. Keep runtime encoding when the text is dynamic, and check explicit span lifetimes around async or interop. [Welcome to C# 11](https://devblogs.microsoft.com/dotnet/welcome-to-csharp-11/)

## List patterns and span matching

```csharp
public static class Patterns
{
    public static bool HasFrame(int[] values) => values is [1, .., 9];

    public static bool IsStart(System.ReadOnlySpan<char> command) => command is "start";
}
```

- `[first, .., last]` expresses a shape check over a type with a usable length or count and indexer. A bare `..` ignores the middle and needs no slicing member. `.. var middle` needs slicing support and can allocate, for example with arrays. An arbitrary `IEnumerable<T>` lacks the count and indexer contract. Preserve lazy enumeration where it matters.
- `Span<char>` and `ReadOnlySpan<char>` can match constant strings without converting to `string`. Match behavior is ordinal and case-sensitive. Keep an explicit comparison for culture or case rules. [Pattern matching reference](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/operators/patterns)

## Required members, auto-default structs, and file-local types

```csharp
public sealed class Request
{
    public required string Path { get; init; }
}

public static class Requests
{
    public static Request Root() => new() { Path = "/" };
}
```

- `required` on a field or property makes object creation through ordinary C# callers supply it, unless the selected constructor is marked `[SetsRequiredMembers]`. It is independent of nullability and runtime validation. The attribute is a promise to the compiler, which does not prove the constructor sets the members. Check inherited requirements, accessibility, constructor chaining, serializers, and existing callers. Types with required members cannot satisfy a `new()` constraint.
- Auto-default structs let the compiler initialize fields left unassigned by a constructor. This can remove boilerplate zero assignments. Keep deliberate nonzero defaults and verify initialization order and `default(S)` behavior. A field initializer is a separate rule.
- `file class Helper` and other file-local types are visible only in their declaring source file. They are useful in generated code where separate files may need the same helper name. Keep a file-local type out of member signatures on non-file-local types, and check references before changing `internal` to `file`. [C# 11 proposals](https://github.com/dotnet/csharplang/tree/main/proposals/csharp-11.0)

## Generic math, operators, and native integers

```csharp
public static class Numbers
{
    public static T Sum<T>(T left, T right) where T : System.Numerics.INumber<T>
        => left + right;
}
```

- Static abstract or virtual interface members let generic code call static members through constrained type parameters. Use the narrowest interface that covers the operations needed. The standard generic math interfaces come from .NET 7. Check the runtime, explicit implementations, overflow rules, and numeric behavior before unifying existing arithmetic overloads.
- C# 11 adds checked forms of supported user-defined arithmetic operators and explicit conversions. Provide the corresponding unchecked form. Verify which form the caller binds to under `checked` and `unchecked`. `>>>` is the zero-fill right shift for built-in integers, including signed operands. User-defined shift operators can also use right operands other than `int`.
- `nint` and `nuint` now alias `IntPtr` and `UIntPtr`. Check previously distinct overloads and native-width arithmetic when upgrading. [Generic math](https://learn.microsoft.com/en-us/dotnet/standard/generics/math) · [C# 11 proposals](https://github.com/dotnet/csharplang/tree/main/proposals/csharp-11.0)

## Ref safety, attributes, and compiler changes

- A `ref struct` can hold `ref` fields on a runtime that supports them. `scoped` constrains escape of a reference or ref-like value. Use it to express actual lifetimes. A default `ref` field may hold a null reference. Preserve aliasing, mutability, and lifetime guarantees when replacing copies with references.
- Generic attributes such as `[Handles<string>]` can express a compile-time type in the attribute type itself. Use closed type arguments representable in attribute metadata. Type parameters, `dynamic`, nullable reference annotations, and tuple element names are unsuitable as written. Check reflection consumers before changing an attribute's metadata identity.
- `nameof` in a method or lambda attribute can refer to parameters in that declaration's scope. For example, `[return: NotNullIfNotNull(nameof(text))]` can describe the relationship to parameter `text`. Unbound generic types in `nameof` arrive in [C# 14](csharp-14.md).
- The compiler can cache delegates for static method group conversions. Take allocations as a measurement question, especially for instance receivers or generics. Keep equality and delegate identity assumptions out of allocation refactors. For upgrades, check new diagnostics such as warning wave 7 against the project's `AnalysisLevel` and warning policy. [C# version history](https://learn.microsoft.com/en-us/dotnet/csharp/whats-new/csharp-version-history#c-version-11)
