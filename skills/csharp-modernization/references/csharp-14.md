# C# 14

The SDK-style default for `net10.0`. The examples use C# 14 syntax.

## Extension members and operators

```csharp
public static class StringExtensions
{
    extension(string text)
    {
        public bool HasContent => !string.IsNullOrWhiteSpace(text);
    }

    extension(string)
    {
        public static string DefaultLabel => "Untitled";
    }
}
```

- Put extension blocks in a non-nested, nongeneric static class. The receiver can be generic. The first block exposes `text.HasContent`. The second exposes `string.DefaultLabel` when the declaring namespace is in scope. Extension properties compute or forward access through their bodies and cannot add per-instance storage to the receiver.
- Classic `this`-parameter extension methods are still supported. Keep a public declaration's binary and source callers in mind when migrating. Real members have precedence when applicable, and imports affect extension lookup. Check for ambiguous calls after adding extensions.
- C# 14 supports extension operators in extension blocks, including static operators and eligible in-place operators. Predefined and applicable non-extension operators are considered first. Check the receiver, operator pairing rules, and caller binding. On C# 14, expose methods such as `GetAt` for extension-based indexing. [C# 15](csharp-15.md) adds extension indexers. Expression trees can call extension methods, while extension property access produces CS9296. [Extension members](https://learn.microsoft.com/en-us/dotnet/csharp/programming-guide/classes-and-structs/extension-methods) · [Extension operators proposal](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/proposals/csharp-14.0/extension-operators)

## `field`-backed properties

```csharp
public sealed class Limits
{
    public int Count
    {
        get;
        set => field = value >= 0 ? value : throw new System.ArgumentOutOfRangeException(nameof(value));
    }
}
```

- `field` in a property accessor accesses compiler-generated storage. Use it when the property owns its backing state and needs custom validation or other accessor logic. A property initializer writes backing storage directly, so preserve validation if the old initialization path called the setter.
- Check every access to the original field, including direct constructor writes, `ref` or interlocked operations, field attributes, serializers, and reflection. Keep explicit storage when its identity or accessibility matters. `field` now has contextual meaning inside accessors. Refer to an existing member with `this.field` or escape an identifier as `@field`. [What's new in C# 14](https://learn.microsoft.com/en-us/dotnet/csharp/whats-new/csharp-14#the-field-keyword)

## Null-conditional assignment

```csharp
public static class Updates
{
    public static void SetFirst(int[]? values, System.Func<int> next)
    {
        values?[0] = next();
    }
}
```

Use `?.` or `?[]` on the left of simple and compound assignments when a null receiver should skip the update. The receiver is evaluated once. The index and right-hand side are evaluated only if that access proceeds. Retain surrounding guard logic and verify side effects when replacing a null check. `++`, `--`, `ref` use, and expression-tree conversion remain restricted. [Null-conditional assignment proposal](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/proposals/csharp-14.0/null-conditional-assignment)

## Span conversions, `nameof`, and lambda parameters

- C# 14 treats supported array-to-span and span-to-read-only-span conversions as language conversions. These participate in type inference and extension receiver binding, with rules for eligible `ReadOnlySpan<T>` covariance and `string` to `ReadOnlySpan<char>`. Recheck calls where spans and `IEnumerable<T>` or array overloads compete. For example, use `Enumerable.Reverse(array)` if that was the intended binding. Watch for unsupported span values inside expression trees. [First-class span types](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/proposals/csharp-14.0/first-class-span-types) · [Roslyn breaking changes for .NET 10](https://learn.microsoft.com/en-us/dotnet/csharp/whats-new/breaking-changes/compiler%20breaking%20changes%20-%20dotnet%2010)
- `nameof(System.Collections.Generic.List<>)` returns `"List"`. Use it where only the generic type's simple name matters. It has no namespace, arity, or type arguments, so keep reflection-based names where those details matter.
- A target-typed lambda can omit parameter types while using `ref`, `in`, `out`, `ref readonly`, or `scoped`. For example, a compatible `TryParse<int>` delegate can take `(text, out result) => int.TryParse(text, out result)`. Match the target delegate's modifiers and keep explicit parameter types for `params` lambdas. [What's new in C# 14](https://learn.microsoft.com/en-us/dotnet/csharp/whats-new/csharp-14)

## Partial events and constructors

- A partial event has a field-like defining declaration and an implementation with both `add` and `remove` accessors. Manage subscription storage and thread safety in the implementation.
- A partial instance constructor has a defining signature and an implementation with the body. Put any `this(...)` or `base(...)` initializer on the implementation. Match accessibility and signature. Check generated members and initialization order when converting an existing constructor. [Partial members](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/keywords/partial-member)

## User-defined compound assignment and increment operators

```csharp
public sealed class Counter
{
    public int Value { get; private set; }

    public void operator +=(int amount) => Value += amount;
}
```

An instance compound assignment operator returns `void` and takes one operand. Instance `++` and `--` take no operand parameters and also return `void`. Use these for intentional in-place mutation. Check aliases, assignable struct receivers, and which expression forms choose the instance operator or fall back to a static operator. In particular, a consumed postfix result has to preserve the old value. Check `checked` behavior and the matching unchecked declaration when supplying a checked form. [Compound assignment proposal](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/proposals/csharp-14.0/user-defined-compound-assignment)

## File-based apps and compiler changes

- The .NET 10 SDK can run a `.cs` file as an app with `dotnet run --file app.cs`. File-based apps can use top-of-file `#:` directives such as `#:package PackageId@1.2.3`, `#:project ../Library/Library.csproj`, `#:property Name=Value`, and `#:sdk Microsoft.NET.Sdk.Web`. The SDK reads these directives for build configuration. SDK builds that support `#:include` can add source files such as `#:include Helpers.cs`. On Unix, a first-line shebang can make the file directly runnable. Use a project file when the app depends on project-level build or packaging conventions. [File-based apps](https://learn.microsoft.com/en-us/dotnet/core/sdk/file-based-apps)
- Expression-tree method calls can omit optional arguments and use in-position named arguments. The compiler lowers them into ordinary call arguments. Out-of-order named arguments remain restricted. Verify the provider still translates the resulting call. [Expression tree proposal](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/proposals/csharp-14.0/optional-and-named-parameters-in-expression-trees)
- The async entry-point wrapper can use runtime-provided `AsyncHelpers.HandleAsyncEntryPoint` when available. It falls back to the awaiter-based path on runtimes without that helper. This is a compiler and runtime detail. Preserve the program's exit code and exception behavior when changing startup code. [Async Main code generation proposal](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/proposals/csharp-14.0/async-main-update)
