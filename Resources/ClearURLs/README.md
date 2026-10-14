# ClearURLs rules

`data.minify.json` is the rule database of [ClearURLs](https://gitlab.com/ClearURLs/rules),
© Kevin Röbert, licensed under the GNU LGPL-3.0. It is shipped unmodified as the Clean Links
module's built-in fallback; the module downloads newer copies from
`https://rules2.clearurls.xyz/data.minify.json` (checked against `rules.minify.hash`).

Refresh the built-in copy before a release:

```sh
curl -sSfL -o Resources/ClearURLs/data.minify.json https://rules2.clearurls.xyz/data.minify.json
```
