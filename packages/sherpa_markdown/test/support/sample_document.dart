/// A representative model answer exercising every construct the parser
/// supports. Shared by the parser, widget, golden and benchmark tests.
library;

const sampleDocument = r'''
# Streaming Markdown

Sherpa renders **bold**, *italic*, ***both***, ~~struck~~ and `inline code`,
plus [links](https://example.com/docs "Docs") and autolinks like
https://sherpa.example.org/a_b_c. Prices such as $5 and $10 stay text,
while $E = mc^2$ and \(a^2 + b^2 = c^2\) are math.

Setext heading
--------------

A line with a hard break
and a backslash break\
done.

## Lists

- First item
- Second item with a nested list:
  1. one
  2. two
     - deep
- [ ] open task
- [x] finished task

3. starts at three

   with a second paragraph (loose list)
4. four

> A quote with **emphasis**
> - and a list inside
continued lazily.

## Code

```dart
void main() {
  print('hello, world');
}
```

~~~python
def greet(name):
    return f"hi {name}"
~~~

    indented code block

| Model | Size | Speed |
|:------|:----:|------:|
| Qwen3 | 0.6B | 42 t/s |
| Gemma | 1B | 30 t/s |

***

$$
\int_0^1 x^2\,dx = \frac{1}{3}
$$

\[
e^{i\pi} + 1 = 0
\]

<div class="note">raw <b>html</b> is shown as text</div>

![diagram](https://images.example.net/diagram.png)

A very long URL: https://example.com/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/end
''';
