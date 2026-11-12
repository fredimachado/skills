# C# 13

The SDK-style default for `net9.0`. The examples use C# 13 syntax.

## `params` collections and collection-expression overloads

```csharp
public static class Numbers
{
    public static int Sum(params System.ReadOnlySpan<int> values)
    {
        var total = 0;
        foreach (int value in values)
            total += value;
        return total;
    }

    public static int Example() => Sum(1, 2, 3);
}
```

- `params` accepts supported collection types in addition to arrays. These include spans, certain collection interfaces, and concrete types that meet collection-expression construction requirements. Use a span where consumption is synchronous and its lifetime fits. Check allocation and copying at representative call sites. [Params collections proposal](https://github.com/dotnet/csharplang/blob/main/proposals/csharp-13.0/params-collections.md)
- Adding a span overload can redirect existing calls on recompilation. In expression trees, expanded non-array `params` arguments are unsupported, and ref-like values have separate restrictions. Keep an explicit array or cast at the call site if the original array overload is needed.
- C# 13 refines how a collection expression converts to competing targets. Element conversions can affect which overload wins, and span targets can be preferred over arrays in eligible cases. Verify binding with the actual argument types and language version. [Better conversion from collection expressions](https://github.com/dotnet/csharplang/blob/main/proposals/csharp-13.0/collection-expressions-better-conversion.md)

## `System.Threading.Lock`

```csharp
public sealed class Counter
{
    private readonly System.Threading.Lock _gate = new();
    private int _value;

    public void Increment()
    {
        lock (_gate)
            _value++;
    }
}
```

When the lock expression's compile-time type is `System.Threading.Lock`, the compiler uses its `EnterScope()` and disposal protocol. An expression typed as `object` uses `Monitor`, which is a different lock even on the same instance. Use a dedicated, consistently typed lock on .NET 9 or later. Migrate all access paths protecting the same state together. Check for `Monitor.Wait` and `Pulse`, wrappers, and casts before converting. Keep critical sections synchronous. [Lock statement reference](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/statements/lock)

## Ref safety in async methods, iterators, and generics

```csharp
public static class Readers
{
    public static async System.Threading.Tasks.Task<int> FirstAsync(int[] items)
    {
        await System.Threading.Tasks.Task.Yield();
        System.ReadOnlySpan<int> values = items;
        return values[0];
    }
}
```

- Ref locals and ref-like values can be used in async methods and iterators where they stay within a synchronous region. Keep them from crossing an `await` or `yield` boundary. Unsafe blocks and other permitted unsafe contexts can coexist with async or iterator code. Keep `await` and `yield` in safe contexts and preserve the build's unsafe-code policy.
- A `ref struct` can implement interfaces, but it cannot be boxed or converted to an interface value. Implement required instance members even where the interface supplies defaults. Call explicit implementations through a constrained type parameter, for example `where T : IReader, allows ref struct`.
- Put `allows ref struct` last in the constraint list. It permits ref-like type arguments and obligates the generic implementation to obey ref-safety rules. Check runtime support for byref-like generics. Existing generic APIs such as `List<T>` accept ref-like arguments only if their type parameter supports them. [What's new in C# 13](https://learn.microsoft.com/en-us/dotnet/csharp/whats-new/csharp-13) · [Ref struct interfaces proposal](https://github.com/dotnet/csharplang/blob/main/proposals/csharp-13.0/ref-struct-interfaces.md)

## Partial properties and indexers

```csharp
public partial class Settings
{
    public partial int Level { get; set; }
}

public partial class Settings
{
    private int _level;

    public partial int Level
    {
        get => _level;
        set => _level = value;
    }
}
```

Use partial properties and indexers to pair a defining signature with an implementation, for example in a source generator. Match the signatures and implement the accessors. A second `get; set;` is another defining declaration in C# 13. `field` was available as a preview here and is stable in [C# 14](csharp-14.md). [Partial members](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/keywords/partial-member)

## Smaller changes and library overload priority

- Use `\e` for U+001B, the escape character. It expresses intent directly in terminal sequences and avoids `\x` consuming following hex digits. Check expected bytes where protocol output matters.
- In object initializers, a nested indexer initializer can now use implicit from-end indexing, for example `new Batch { Values = { [^1] = 42 } }` for a writable, nonempty array. This updates the existing member. Verify its length, allocation, and initialization order.
- Natural method group typing prunes inapplicable candidates at each scope, including generic methods with the wrong arity or unsatisfied constraints. A `var` assignment may bind differently after upgrading. Preserve the intended delegate signature explicitly where that matters.
- `[OverloadResolutionPriority(1)]` can steer eligible overload selection on recompilation. The default priority is zero. The compiler considers applicability and groups candidates by declaring type before removing lower-priority candidates. Use it for a deliberate library API change and test both existing binaries and recompiled callers. [C# 13 proposals](https://github.com/dotnet/csharplang/tree/main/proposals/csharp-13.0)
