# Markdown to html converter

This script converts a structure of Markdown files into a HTML site.
The script is written in [Pike](https://github.com/pikelang/Pike) so you need
that to be installed to utilize this script. The Markdown module is not yet 
part of Pike, but it will be in the offical release of Pike 8.0.


## Usage

The most simple way to use this script is:

```
pike build.pike /path/to/markdown/sources /path/to/output/directory
```

In this case the default template will be used and all the Markdown source files
will ge a corresponding HTML file in the output directory. The directory
structure in `sources` will be kept in `output`.

All resources (css and images) in the HTML template file will be inlined in the 
resulting HTML files, to the HTML structure will be totally self contained.


### Options

* **-d, --devel**: Will not inline the CSS. Useful while hacking the CSS so that
  you don't need to generate the entire structure to see changes.

* **-c=<path>, --config=<path>**: Path to config file to use.

* **-t=<path>, --template=<path>**: Path to template directory.


## Configuration

The easiest way to configure this script is to pass a configuration file as 
argument to the script. The configuration format is `JSON`.

```json
{
  "source_path"      : null,
  "destination_path" : null,
  "template_path"    : null,
  "menufile"         : null,
  "minify_html"      : true,
  "skip"             : []
}
```

* **`source_path`**: The path to the directory where the Markdown files reside.

* **`destination_path`**: The path to where the HTML files should be written. If
  this file doesn't exist it will be created.

* **`template_path`**: The path to the directory where the templates reside. If
  this is `null` the default template will be used.

* **`menufile`**: If you wan't a menu generated on all pages, the easiest way
  is to create a *site index*, with links to all the pages, in the main 
  Markdown file. Note that the section is surrounded by two comment tags.

  ```md
  <!-- menu -->

  * [First section](first_section/index.md)
    * [To begin](first_section/begin.md)
    * [To continue](first_section/continue.md)
  * [Second section](second_section/index.md)
    * [Pause](second_section/pause.md)
    * [Continue](second_section/continue.md)
  * [Third section](third_section/index.md)
  * [Fourth section](fourth_section/index.md)

  <!-- endmenu -->
  ```

  This will act as the menu for the entire site, nd will be put on all pages.
  This section will be removed from the resulting HTML file.

* **minify_html**: The HTML in the template is minified (i.e. all newlines and
  whitespace between a closing and opening tag is removed) per default. I you
  want to keep the whitespace set this to `false`.

* **skip**: An array of regexp of files to skip. Note that this is matched on
  every file's and diretorie's absolute path. **NOTE!** dot files are skipped
  per default.


## TODO

The menu rendering doesn't handle more than one level at the moment.