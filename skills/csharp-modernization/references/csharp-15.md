# C# 15

The SDK-style default for `net11.0`. The six stable features below work with C# 15. The .NET 11 SDK also includes a separate memory-safety preview. [What's new in C# 15](https://learn.microsoft.com/en-us/dotnet/csharp/whats-new/csharp-15) · [.NET 11 SDK](https://dotnet.microsoft.com/en-us/download/dotnet/11.0)

## Collection expression arguments

```csharp
using System;
using System.Collections.Generic;

public static class Names
{
    public static HashSet<string> Distinct(string[] values) =>
        [with(StringComparer.OrdinalIgnoreCase), .. values];

    public static List<string> Copy(string[] values) =>
        [with(capacity: values.Length), .. values];
}
```

- Put `with(...)` first. For a concrete collection it binds to an accessible constructor, so a target with only parameterized constructors can work. A `CollectionBuilderAttribute` factory receives the supplied arguments before its final `ReadOnlySpan<T>` parameter. Use named arguments to clarify intent and help resolve constructor overloads.
- `IList<T>` and `ICollection<T>` targets accept an empty `with()` or a capacity argument. The compiler constructs a `List<T>`. `IEnumerable<T>`, `IReadOnlyCollection<T>`, and `IReadOnlyList<T>` accept only an empty `with()`. Arrays and spans reject the argument element. Use an ordinary dictionary initializer for key-value pairs.
- The constructor or builder arguments are evaluated before the element expressions. Spread enumeration can be deferred relative to later element evaluation. Check ordering when rewriting code with side effects. The arguments bind after the target type is chosen and do not infer a generic element type. Use an explicit target or type argument when needed. Escape a method named `with` as `@with(...)` when calling it at the start of a collection element. [Collection expression arguments](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/operators/collection-expressions#collection-expression-arguments)

## Union types

```csharp
public sealed record Found(string Path);
public sealed record Missing(string Reason);
public union LookupResult(Found, Missing);

public static class Lookups
{
    public static LookupResult Success(string path) => new Found(path);

    public static string Describe(LookupResult result) => result switch
    {
        Found found => found.Path,
        Missing missing => missing.Reason,
        null => "No result",
    };
}
```

- Use a union for a fixed set of case types that need no common base. Use distinct case types when equal underlying payload types have different meanings. Prefer a closed hierarchy for owned classes that share state or polymorphic behavior. Check API and serialization compatibility before replacing an existing result type.
- A `union` declaration emits a struct with an `object? Value`, a public constructor per case, `[Union]`, and `IUnion`. The attribute and interface come from the .NET 11 reference assemblies. The wrapper can box value-type cases. Standard implicit conversions into a case type can trigger a union conversion, and overlapping cases can make a conversion ambiguous. Check binding when changing public signatures.
- Switch on the union itself for exhaustiveness. Type patterns and typed recursive patterns test the contents. An untyped property pattern uses the wrapper's members. `var` captures the wrapper. Use an explicit `null` arm when a nullable case, nullable wrapper, or default-initialized struct can reach the switch. A `default` union contains null even when its declared case types are nonnullable. An explicit null arm keeps missing-case diagnostics useful when new cases are added.
- For a custom representation, use `[Union]` with public single-case constructors and an `object? Value` getter. Implement `IUnion` where consumers rely on it. The optional `HasValue` and case-specific `TryGetValue` pattern can avoid boxing during matching. Confirm the access pattern and measure before replacing generated storage. [Union types](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/builtin-types/union)

## Closed hierarchies

```csharp
public closed record class JobState;
public sealed record class Queued : JobState;
public sealed record class Running(int Percent) : JobState;

public static class Jobs
{
    public static string Describe(JobState state) => state switch
    {
        Queued => "Queued",
        Running running => $"{running.Percent}%",
    };
}
```

- A `closed` class or record class is implicitly abstract. Its direct subclasses belong to the same assembly and module. Mark intermediate classes `closed` or leaves `sealed` when you also intend to restrict further derivation. A generic direct descendant must use all its type parameters in the base type specification.
- An exhaustive switch expression handles each applicable direct descendant. A parent arm covers its descendants, so place more specific arms first. Add a `null` arm for nullable inputs. Inaccessible or otherwise unnameable descendants can require a fallback. If external callers should be able to enumerate the cases, design their accessibility accordingly.
- Adding `closed` to a public class restricts where it can be subclassed. Adding a descendant can invalidate consumers' exhaustive switches on recompilation. Treat the subtype set as part of the public contract. Escape an existing identifier as `@closed` when modifier parsing changes. [Closed modifier](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/keywords/closed)

## Extension indexers

```csharp
public sealed class Readings(int[] values)
{
    public int[] Values { get; } = values;
}

public static class ReadingExtensions
{
    extension(Readings readings)
    {
        public int Count => readings.Values.Length;
        public int this[int index] => readings.Values[index];
    }
}

public static class ReadingQueries
{
    public static int Last(Readings readings) => readings[^1];
}
```

- Declare the indexer in a C# 14-style extension block with a named receiver, inside a non-nested, nongeneric static class. The feature supports getters, setters, and eligible ref returns. Use it when indexing is a natural operation on the receiver. An indexer over a lazy sequence may repeatedly enumerate it, so keep that cost visible.
- Lookup checks applicable instance indexers and implicit instance index or range support before extension indexers and implicit extension support. An extension `Length` or `Count` can combine with indexing and slicing members for `^`, ranges, and list patterns. Check scope and imported extensions. The receiver and index arguments drive type inference for a setter. The assigned value does not.
- Arrays and strings use their own indexing rules. Use ordinary methods where an extension indexer would appear inside an expression tree. Verify bounds and allocation behavior when adding index-from-end or slicing support. [Extension indexers](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/keywords/extension#extension-indexers)

## Labeled `break` and `continue`

```csharp
public static class Search
{
    public static int FindRow(int[][] rows, int value)
    {
        int found = -1;
        search: for (int row = 0; row < rows.Length; row++)
        {
            foreach (int item in rows[row])
            {
                if (item == value)
                {
                    found = row;
                    break search;
                }
            }
        }

        return found;
    }
}
```

Use a labeled jump when a flag or `goto` exists to leave or advance an enclosing loop and execution continues within the method. Put the label immediately before the target statement. `break label;` can leave an enclosing loop or switch statement. `continue label;` advances an enclosing loop. Both target statements in the same function and follow ordinary `finally` rules. Check cleanup and loop updates when replacing existing control flow. [Jump statements](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/statements/jump-statements) · [IDE0410](https://learn.microsoft.com/en-us/dotnet/fundamentals/code-analysis/style-rules/ide0410)

## Non-virtual static interface members on older runtimes

```csharp
public interface IMeasurement
{
    public static double ToMeters(double centimeters) => centimeters / 100;
}

public static class Measurements
{
    public static double Example() => IMeasurement.ToMeters(250);
}
```

The C# 15 compiler permits non-virtual static interface helpers with eligible accessibility even on targets without default interface implementation support. Call the helper on the interface. Instance default implementations, static abstract or virtual members, and protected interface members still require runtime support. Check the library's target and consumer compiler policy before using this capability in shared code. [Interface members and runtime support](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/keywords/interface#static-interface-members-and-runtime-support)

## Memory-safety preview

For explicitly requested preview work, check the exact SDK and the project's effective settings. `<LangVersion>preview</LangVersion>` enables the new syntax and pointer relaxations. `<Features>$(Features);updated-memory-safety-rules</Features>` enables the updated rules, including caller obligations for requires-unsafe members. `<AllowUnsafeBlocks>true</AllowUnsafeBlocks>` enables explicit safety syntax such as `unsafe(expression)`.

The preview distinguishes pointer declarations from operations that access unmanaged memory. `unsafe(expression)` provides a narrow unsafe context. `safe` can annotate eligible declarations such as audited extern members. With the updated rules, callers of requires-unsafe members need an unsafe context. Inspect interop contracts, pointer dereferences, and caller changes before altering annotations. [Memory-safety preview](https://learn.microsoft.com/en-us/dotnet/csharp/whats-new/csharp-15#memory-safety) · [Compiler options](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/compiler-options/language#enable-the-updated-memory-safety-rules)
