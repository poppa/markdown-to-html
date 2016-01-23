#!/usr/bin/env pike
/*
  Author: Pontus Östlund <https://profiles.google.com/poppanator>

  To use this script you will need Pike 8.0 or greater (or at the moment
  you will need at Git version of Pike since the Markdown module isn't yet
  compiled with the public release).
*/

#if !constant(Parser.Markdown.Marked)

int main(int argc, array(string) argv)
{
  werror("Missing Markdown module. It's available in Pike 8.0 and newer! ");
  return 1;
}

#else /* Parser.Markdown.Marked */

import Regexp.PCRE;
constant Re = Regexp.PCRE.Widestring;

#define SKIP(X) (sizeof(((re_skip->match(X)) - ({ 0 }))) > 0)

private string source_path;
private string destination_path;
private string template_path;
// Skip all dot files
private array(Re) re_skip = ({ Re("\\/\\.") });
private Parser.HTML parser;
private string template;
private string menu_file;
private bool minify_html = true;
private int file_count;
private mapping replacements = ([
  "title":      0,
  "data":       0,
  "build_date": 0,
  "menu":       ""
]);
// Markdown options
private mapping options;
private mapping menu_struct = ([]);
private array menu_order;
private int menu_pos = 0;
private bool devmode = false;
private string config_path;
private mapping(string:function) default_containers;

private constant HELP_TEXT = #"
Usage: %s [options] md-source-path detination-path

Options:
  -d, --devmode   Will not embed CSS into the resulting HTML files. Makes it
                  possible to alter the CSS without regenerating the HTML files.

  -c, --config    Path to config file.

  -t, --template  Path to template directory
";

#define HELP sprintf(HELP_TEXT, argv[0])

int main(int argc, array(string) argv)
{
  foreach (Getopt.find_all_options(argv, ({
    ({ "devmode",  Getopt.NO_ARG,  "-d,--devmode"/","  }),
    ({ "config",   Getopt.HAS_ARG, "-c,--config"/","   }),
    ({ "template", Getopt.HAS_ARG, "-t,--template"/"," })
  })), array arg) {
    switch (arg[0]) {
      case "devmode":   devmode = true; break;
      case "config":    config_path = arg[1]; break;
      case "template":  template_path = arg[1]; break;
    }
  }

  argv -= ({ 0 });

  if (config_path) {
    if (!Stdio.exist(config_path)) {
      werror("The path to the config file does not exist!\n");
      return 1;
    }

    mapping t = Standards.JSON.decode(Stdio.read_file(config_path));

    if (t->source_path) {
      source_path = t->source_path;
    }

    if (t->destination_path) {
      destination_path = t->destination_path;
    }

    if (t->skip) {
      foreach (t->skip, string r) {
        re_skip += ({ Re(r) });
      }
    }

    if (!template_path && t->template_path) {
      template_path = t->template_path;
    }

    if (t->menufile) {
      menu_file = t->menufile;
    }

    if (has_index(t, "minify_html")) {
      minify_html = t->minify_html;
    }
  }

  if (template_path && !Stdio.exist(template_path)) {
    werror("The template path \"%s\" does not exist!\n");
    return 1;
  }

  if (!source_path && !destination_path && sizeof(argv) < 3) {
    werror("Missing arguments!\n%s\n", HELP);
    return 1;
  }

  if (!source_path) {
    source_path = argv[1];
  }

  if (!destination_path) {
    destination_path = argv[2];
  }

  if (!Stdio.exist(source_path)) {
    werror("The source path \"%s\" doesn't exist!\n", source_path);
    return 1;
  }

  if (!Stdio.exist(destination_path)) {
    if (!Stdio.mkdirhier(destination_path)) {
      werror("Unable to create destination path. Do you have write permission "
             "to \"%s\"?\n", dirname(destination_path));

      return 1;
    }
  }

  if (!template_path) {
    template_path = combine_path(__DIR__, "template");
  }

  if (!Stdio.exist(combine_path(template_path, "main.html"))) {
    werror("The template dir \"%s\" doesn't have a main HTML template file!\n");
    return 1;
  }

  options = ([
    "newline"     : false,
    "smartypants" : true,
    "highlight"   : set_highlighter()
  ]);

  template = Stdio.read_file(combine_path(template_path, "main.html"));

  parser = Parser.HTML();

  if (minify_html) {
    parser->_set_data_callback(lambda (Parser.HTML pp, string data) {
      if (String.trim_all_whites(data) == "") {
        return "";
      }
    });

    template = parser->feed(template)->finish()->read();
    parser = Parser.HTML();
  }

  parser->add_tags(([
    "link" :  lambda (Parser.HTML pp, mapping attr) {
                string fp = combine_path(template_path, attr->href);
                if (devmode) {
                  attr->href = fp;
                  return ({ sprintf("<link%{ %s='%s'%}>", (array)attr) });
                }
                else {
                  if (Stdio.exist(fp)) {
                    string css = Stdio.read_file(fp);
                    return ({ "<style>" +
                              CSSMinifier()->minify(css) +
                              "</style>" });
                  }
                }
              },
    "img"  :  lambda (Parser.HTML pp, mapping attr) {
      if (attr->src) {
        string fp = combine_path(template_path, attr->src);
        if (Stdio.exist(fp)) {
          string ext = lower_case((attr->src/".")[-1]);
          string mime = "image/";

          switch (ext)
          {
            case "png":  mime += "png"; break;
            case "gif":  mime += "gif"; break;
            case "jpg":
            case "jpeg": mime += "jpeg"; break;
            case "svg":  mime += "svg+xml"; break;
            default:     mime += "any"; break;
          }

          string data = Stdio.read_file(fp);
          data = MIME.encode_base64(data, 1);
          attr->src = "data:" + mime + ";base64," + data;

          return ({ sprintf("<img%{ %s=\"%s\"%}>", (array)attr) });
        }
        else {
          write("WARNING: The image \"%s\" in the template does not exist!\n");
          return 0;
        }
      }
    }
  ]));

  template = parser->feed(template)->finish()->read();
  parser->clear_containers();
  parser->clear_tags();

  replacements->build_date = Calendar.now()->format_mtime();

  write("Starting scanning and parsing...\n");

  int starttime = time();

  if (menu_file) {
    write("\nParsing menu file...");

    menu_file = combine_path(source_path, menu_file);

    int startpos, endpos, startpos_end;

    string menu_file_data = Stdio.read_file(menu_file);

    parser->add_quote_tag("!--",
                          lambda (Parser.HTML pp, string data) {
                            string d = String.trim_all_whites(data);

                            if (d == "menu") {
                              startpos = pp->at()[1];
                              startpos_end = sizeof("<!--" + data + "-->");
                            }
                            else if (d == "endmenu") {
                              endpos = pp->at()[1];
                            }
                          },
                          "--");

    string menu_html = parser->feed(menu_file_data)->finish()->read();
    parser->clear_quote_tags();

    menu_html = String.trim_all_whites(menu_html[startpos+startpos_end..endpos-1]);
    menu_html = Parser.Markdown.marked(menu_html, options);

    parser->add_containers(([
      "a" : lambda (Parser.HTML pp, mapping attr, string data) {
        if (!attr->href) return 0;
        if (sscanf(attr->href, "%*s.md")) {
          if (search(data, "<em>") > -1) {
            return "<span class='fake-link'>" + data + "</span>";
          }

          string html_href = replace(attr->href, ".md", ".html");
          array(string) pts = html_href/"/";

          string base_name      = basename(attr->href);
          string base_name_href = basename(html_href);

          if (!menu_struct[pts[0]]) {
            menu_struct[pts[0]] = ([
              "pos" : menu_pos++,
              "top" : ([ "href"          : attr->href,
                         "html_href"     : html_href,
                         "basename"      : base_name,
                         "basename_href" : base_name_href,
                         "title"         : data ])
            ]);
          }

          if (!menu_struct[pts[0]]->pages) {
            menu_struct[pts[0]]->pages = ({});
          }
          else {
            menu_struct[pts[0]]->pages += ({
              ([ "href"          : attr->href,
                 "html_href"     : html_href,
                 "basename"      : base_name,
                 "basename_href" : base_name_href,
                 "title"         : data ])
            });
          }

          attr->href = replace(attr->href, ".md", ".html");

          return ({ sprintf("<a%{ %s=\"%s\"%}>%s</a>",
                    (array) attr, data) });
        }
      }
    ]));

    parser->feed(menu_html)->finish();
    parser->clear_containers();

    menu_order = allocate(sizeof(indices(menu_struct)));

    foreach (indices(menu_struct), string k) {
      menu_order[menu_struct[k]->pos] = menu_struct[k];
    }

    write("...done!\n");
  }

  default_containers = ([ "h1" : default_h1_handler,
                          "a"  : default_link_handler ]);
  parser = 0;
  parser = Parser.HTML();

  parser->add_containers(default_containers);

  recurse_dir(source_path, handle_path);

  write("\nDone!\nParsed %d files in %.2f seconds.\n\n",
        file_count, time(starttime));

	return 0;
}

mixed default_h1_handler(Parser.HTML pp, mapping attr, string data)
{
  if (!replacements->title)
    replacements->title = data;
}

mixed default_link_handler(Parser.HTML pp, mapping attr, string data)
{
  if (!attr->href) return 0;
  if (sscanf(attr->href, "%*s.md") == 1) {
    attr->href = replace(attr->href, ".md", ".html");
    return ({ sprintf("<a%{ %s=\"%s\"%}>%s</a>",
              (array) attr, data) });
  }
}

void handle_path(string path, string name, void|int depth)
{
  string relpath = (path - source_path)[1..];
  string new_path = replace(path, source_path, destination_path);

  if (SKIP(path)) {
    return;
  }

  if (Stdio.is_dir(path)) {
    if (!Stdio.exist(new_path)) {
      mkdir(new_path);
    }

    return;
  }

  string toppath = "../" * depth;
  if (toppath == "") toppath = "./";
  replacements->top_path = toppath + "index.html";
  replacements->top_class = sprintf("class='%s'",
                                    replace(relpath, "/", "-") - ".md");

  array(string) parts = name/".";

  if (menu_file) {
    array(string) rel_parts = relpath/"/";
    replacements->menu = render_menu(rel_parts[0], relpath, depth);
  }

  if (sizeof(parts) > 1 && lower_case(parts[-1]) == "md") {
    write("  * Parsing: %s\n", name);

    string html = Parser.Markdown.marked(Stdio.read_file(path), options);
    string nn = (parts[..<1] * ".") + ".html";

    replacements->data = fix_links(html);

    if (menu_file && path == menu_file) {
      parser = Parser.HTML();

      int sp, ep;
      parser->add_quote_tag("!--",
                            lambda (Parser.HTML pp, string data) {
                              string d = String.trim_all_whites(data);
                              if (d == "menu") {
                                sp = pp->at()[1]-1;
                              }
                              else if (d == "endmenu") {
                                ep = pp->at()[1];
                                ep += sizeof("<!--" + data + "-->");
                              }
                            },
                            "--");

      parser->feed(replacements->data)->finish();

      string p1 = replacements->data[..sp];
      string p2 = replacements->data[ep..];

      replacements->data = p1 + p2;
    }

    mapping rr = ([]);
    foreach (indices(replacements), string key) {
      rr["${" + key + "}"] = replacements[key];
    }

    html = replace(template, rr);

    new_path = replace(new_path, name, nn);
    Stdio.write_file(new_path, html);

    file_count++;
  }
  else {
    Stdio.cp(path, new_path);
  }
}

string render_menu(string index, string current, void|int depth) {
  int pos = !has_index(menu_struct, index) && -1 || menu_struct[index]->pos;
  String.Buffer sb = String.Buffer();
  function add = sb->add;
  string rel_path = "../" * depth;

  add("<nav class='inner'><p><a href='", rel_path,
      "index.html'", pos == -1 ? " class='selected'" : "",
      ">Start</a></p><ul>");

  foreach (menu_order, mapping sub) {
    bool is_cur = false;

    if (sub->pos == pos) {
      is_cur = true;
    }

    add("<li", (is_cur ? " class='selected'" : ""),
        "><a href='", rel_path + sub->top->html_href, "'>",
        sub->top->title, "</a>");

    if (sizeof(sub->pages) && is_cur) {
      add("<ul>");

      foreach (sub->pages, mapping page) {
        string cls = "normal";
        string href = rel_path + page->html_href;

        if (page->href == current) {
          cls = "selected";
        }
        // Current section, no relative depths
        if (is_cur) {
          href = page->basename_href;
        }

        add("<li class='", cls, "'><a href='", href, "'>",
            page->title, "</a></li>");
      }
      add("</ul>");
    }
  }

  add("</ul></nav>");

  return sb->get();
}

string fix_links(string s)
{
  replacements->title = 0;
  parser = Parser.HTML();
  parser->add_containers(default_containers);
  return parser->feed(s)->finish()->read();
}

void recurse_dir(string path, function cb, void|int depth)
{
  write("\nScanning: %s\n", path);

  foreach (get_dir(path), string p) {
    string fp = combine_path(path, p);

    if (SKIP(fp)) {
      write("  # Skipping %s: %s\n", Stdio.is_dir(fp) ? "dir" : "file", fp);
      continue;
    }

    cb(fp, p, depth);

    if (Stdio.is_dir(fp)) {
      recurse_dir(fp, cb, depth+1);
    }
  }
}

function set_highlighter()
{
#if constant(Tools.Standalone.pike_to_html)
  Tools.Standalone.pike_to_html pth = Tools.Standalone.pike_to_html();
  return lambda (string code, string lang) {
    if (lang && lang == "pike") {
      return pth->convert(code);
    }
    else if (lang && lang == "hilfe") {
      return highlight_hilfe(code, pth);
    }
    return code;
  };
#else
  return 0;
#endif
}

#define next css[i+1]
#define prev css[i-1]
#define curr css[i]

class CSSMinifier
{
  constant DELIMITERS = (< ';',',',':','{','}','(',')' >);
  constant WHITES = (< ' ','\t','\n' >);
  constant WHITES_DELIMS = DELIMITERS + WHITES;

  string minify(string css)
  {
    int len = sizeof(css);
    css += "\0";
    String.Buffer buf = String.Buffer();
    function add = buf->add;
    int(0..1) in_import = 0, in_media = 0;

    outer: for (int i; i < len; i++) {
      int c = css[i];
      switch (c)
      {
        case '\'':
        case '"':
          add(css[i..i]);
          i += 1;
          while (1) {
            add(css[i..i]);
            if (css[i] == c)
              continue outer;
            i += 1;
          }
          break;

        case '@':
          if (next == 'i') {
            in_import = 1;
            add(" ");
          }
          else if (next == 'm') {
            in_media = 1;
            add(" ");
          }
          break;

        case '(':
          if (in_media) {
            add(" (");
            in_media = 0;
            continue outer;
          }

        case ';':
          if (in_import) {
            add(css[i..i], "\n");
            in_import = 0;
            continue outer;
          }
          break;

        case '\r':
        case '\n':
          in_media = 0;
          in_import = 0;
          continue outer;

        case ' ':
        case '\t':
          if (WHITES_DELIMS[prev] || WHITES_DELIMS[next])
            continue outer;
          break;

        case '/':
          if (next == '*') {
            i++;

            int (0..1) keep = 0;
            if (next == '!') {
              keep = 1;
              add ("/*");
            }

            while (i++ < len) {
              if (keep) add (css[i..i]);
              if (curr == '*' && next == '/') {
                if (keep) add ("/\n");
                i++;
                continue outer;
              }
            }
          }
          break;

        case ')': // This is needed for Internet Explorer
          if (!DELIMITERS[next]) {
            add(") ");
            continue outer;
          }
          break;

        case '}':
          add(css[i..i], "");
          continue outer;
      }
      add(css[i..i]);
    }

    return String.trim_all_whites(buf->get());
  }
}

#if constant(Tools.Standalone.pike_to_html)
string highlight_hilfe(string s, Tools.Standalone.pike_to_html ph)
{
  array(string) lines = replace(s, ([ "\r\n" : "\n", "\r" : "\n" ]))/"\n";
  array(string) out = ({});

  foreach (lines, string line) {
    if (sscanf(line, "%[ \t]>%s", string prefix, string code) == 2) {
      if (sizeof(code)) {
        prefix += "&gt;";

        if ((< ' ', '\t' >)[code[0]]) {
          sscanf(code, "%[ \t]%s", string prefix2, code);
          prefix += prefix2;
        }

        code = ph->convert(code);

        if (code[-1] == '\n') {
          code = code[..<1];
        }

        line = sprintf("<span class='input'>%s"
                       "<span class='code'>%s</span>"
                       "</span>", prefix, code);
      }
      else {
        continue;
      }
    }
    else {
      line = sprintf("<span class='output'>%s</span>", line);
    }

    out += ({ line });
  }

  return out * "\n";
}
#endif

#endif