# C# 12

The SDK-style default for `net8.0`. The examples use C# 12 syntax.

## Primary constructors on classes and structs

```csharp
public sealed class Report(string title)
{
    public string Title { get; } = title;
}
```

- Use a primary constructor when initialization is short and the parameters fit naturally into member initializers or the base call. Class and struct parameters are in scope throughout the type. Ordinary non-record types synthesize no public properties for them.
- Initializer-only use can avoid hidden storage. Referencing a parameter directly from instance members can capture it in compiler-generated storage. Check for duplicate storage when a parameter is also assigned to a property or passed to a base constructor. If the original field was `readonly`, preserve the invariant with a get-only property or explicit readonly field where appropriate.
- Explicit secondary constructors must chain to the primary constructor. Adding a primary constructor to a class removes its implicit parameterless constructor. Keep constructor availability, validation order, accessibility, and framework binding where callers depend on them. Structs still have default zero-initialization, so `default(S)` bypasses validation. [Primary constructors tutorial](https://learn.microsoft.com/en-us/dotnet/csharp/whats-new/tutorials/primary-constructors)

## Collection expressions

```csharp
public static class Collections
{
    public static int[] Wrap(int[] items) => [0, .. items, 9];

    public static System.Collections.Generic.List<string> Empty() => [];
}
```

- `[]` and `[a, ..source, b]` need a target type. `var values = [1, 2];` gives CS9176. Choose an array, span, supported collection interface, concrete collection, or custom collection with a compatible builder. A `CollectionBuilderAttribute` builder takes a `ReadOnlySpan<T>` and returns the target collection.
- Preserve concrete type, mutability, empty-instance identity if observable, configured capacity or comparer, and any collection-specific invariants. Collection expressions eagerly construct their result even with an `IEnumerable<T>` target. Keep lazy sequences where callers depend on deferred evaluation. In C# 12, use constructors or initializers for collections requiring constructor arguments or dictionary entries. [C# 15](csharp-15.md) adds constructor and builder arguments for eligible collection expressions.
- Spread expressions evaluate in source order, but the timing of enumeration can differ from an explicit sequence of calls. Check exceptions, side effects, and the result of changing overloads. Use a typed local or cast when overload selection matters. Preserve span lifetime and escape constraints. [Collection expressions proposal](https://github.com/dotnet/csharplang/blob/main/proposals/csharp-12.0/collection-expressions.md)

## Inline arrays

```csharp
[System.Runtime.CompilerServices.InlineArray(8)]
public struct SampleBuffer
{
    private int _first;
}

public static class Buffers
{
    public static int First()
    {
        SampleBuffer buffer = default;
        buffer[0] = 42;
        return buffer[0];
    }
}
```

`InlineArrayAttribute` describes fixed-length storage in a struct with one instance field and a positive length. Use it for a measured buffer or layout need on a runtime that supports inline arrays. Check struct copy costs, ref escape, bounds checks, and equality and hashing behavior on the deployed runtime. For example, .NET 9 and later default `Equals` and `GetHashCode` implementations throw on inline-array types. [Inline arrays](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/builtin-types/struct#inline-arrays)

## Lambda defaults, `params`, and aliases

```csharp
using Point = (int X, int Y);

public static class Syntax
{
    public static Point Origin()
    {
        var coordinate = (int value = 0) => value;
        var count = (params int[] values) => values.Length;
        return (coordinate(), count());
    }
}
```

- Lambda parameters can have default values and a `params` array. Natural typing preserves the call shape using a suitable delegate. When assigned to a different delegate type, its `Invoke` signature controls the available defaults and `params` behavior. Method group natural typing can also preserve default and `params` metadata. Check delegate compatibility and omitted-argument behavior. [Lambda and method group defaults](https://github.com/dotnet/csharplang/blob/main/proposals/csharp-12.0/lambda-method-group-defaults.md)
- `using` aliases can name tuple, array, constructed generic, and other types beyond ordinary named types. An alias does not create a distinct type. A top-level nullable reference type cannot be aliased. Pointer aliases require `using unsafe` and unsafe compilation. [C# 12 proposals](https://github.com/dotnet/csharplang/tree/main/proposals/csharp-12.0)

## `ref readonly` parameters and experimental APIs

- `ref readonly` expresses a read-only by-reference parameter that expects a variable location. Prefer `in` at the call site where appropriate. An omitted modifier or an rvalue can produce a warning under the compatibility rules. Changing `in`, `ref`, or by-value parameters can affect overloads, method groups, metadata, and callers. Check defensive copies and actual lifetime requirements. [Ref readonly parameters proposal](https://github.com/dotnet/csharplang/blob/main/proposals/csharp-12.0/ref-readonly-parameters.md)
- `[Experimental("LIB001")]` marks an API as experimental and produces a diagnostic with the chosen ID at use sites. Use it when the author intends an opt-in contract, and keep the diagnostic ID stable. The attribute shipped with .NET 8. Interceptors were listed as an experimental compiler feature in C# 12. Treat existing interceptor code as compiler and generator-specific, and keep it out of stable modernization edits. [What's new in C# 12](https://learn.microsoft.com/en-us/dotnet/csharp/whats-new/csharp-12)
