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
  werror("Missing Markdown module. It's available in Pike 8.1 and newer! ");
  return 1;
}

#else /* Parser.Markdown.Marked */

import Regexp.PCRE;
constant Re = Regexp.PCRE.Widestring;

#define SKIP(X) (sizeof((re_skip->match(X)) - ({ 0 })) > 0)

private string source_path;
private string destination_path;
private string template_path;
// Skip all dot files
private array(Re) re_skip = ({ Re("\\/\\.") });
private Parser.HTML parser;
private string template;
private string menu_file;
private bool keep_menu = false;
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
private bool source_is_dest = false;
private string tmp_file;
private bool regenerate_all = false;
private bool silent = false;
private mapping info;
private mapping special_links = ([]);

private constant HELP_TEXT = #"
Usage: %s [options] md-source-path detination-path

Options:
  -d, --devmode     Will not embed CSS into the resulting HTML files. Makes it
                    possible to alter the CSS without regenerating the HTML files.

  -c, --config      Path to config file.

  -t, --template    Path to template directory

  -s, --silent      Don't write so much to stdout goddammit!

  -r, --regenerate  Force regeneration of all files.
";

#define HELP sprintf(HELP_TEXT, argv[0])

int main(int argc, array(string) argv)
{
  foreach (Getopt.find_all_options(argv, ({
    ({ "devmode",  Getopt.NO_ARG,  "-d,--devmode"/","    }),
    ({ "config",   Getopt.HAS_ARG, "-c,--config"/","     }),
    ({ "template", Getopt.HAS_ARG, "-t,--template"/","   }),
    ({ "silent",   Getopt.NO_ARG,  "-s,--silent"/","     }),
    ({ "regen",    Getopt.NO_ARG,  "-r,--regenerate"/"," })
  })), array arg) {
    switch (arg[0]) {
      case "devmode":   devmode        = true;   break;
      case "config":    config_path    = arg[1]; break;
      case "template":  template_path  = arg[1]; break;
      case "silent":    silent         = true;   break;
      case "regen":     regenerate_all = true;   break;
    }
  }

  argv -= ({ 0 });

  parse_config();

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

  string template_file = combine_path(template_path, "main.html");

  if (!Stdio.exist(template_file)) {
    werror("The template dir \"%s\" doesn't have a main.html template file!\n");
    return 1;
  }

  mapping envn = getenv();
  tmp_file = envn->TMPDIR || envn->TMP || envn->TEMP || "/tmp";

  if (!Stdio.is_dir(tmp_file)) {
    werror("No TMP dir could be resolved!\n");
    return 1;
  }

  tmp_file = combine_path(tmp_file, "md2html.json");

  if (!Stdio.exist(tmp_file)) {
    Stdio.write_file(tmp_file, "{}");
  }

  info = Standards.JSON.decode(Stdio.read_file(tmp_file));

  int template_mtime = file_stat(template_file)->mtime;

  if (!info->template_mtime || info->template_mtime < template_mtime) {
    if (!silent) {
      werror("* Template is changed. Will regenerate all.\n");
    }

    regenerate_all = true;
  }

  info->template_mtime = template_mtime;

  if (!info->mtimes) {
    info->mtimes = ([]);
  }

  foreach (info->mtimes; string p; int ts) {
    if (Stdio.exist(p)) {
      if (ts < file_stat(p)->mtime) {
        regenerate_all = true;
        break;
      }
    }
  }

  options = ([
    "newline"     : false,
    "smartypants" : true,
    "highlight"   : set_highlighter()
  ]);

  template = Stdio.read_file(template_file);
  template = minify_template(template);
  template = parse_template(template);

  replacements->build_date = Calendar.now()->format_mtime();

  if (source_path == destination_path) {
    source_is_dest = true;
    re_skip += ({ Re("\\.html$") });
  }

  parse_menu();

  if (menu_file) {
    int menu_mtime = file_stat(menu_file)->mtime;

    if (!info->menu_mtime || info->menu_mtime < menu_mtime) {
      if (!silent) {
        werror("* Menu changed. Will regenerate all.\n");
      }

      regenerate_all = true;
      info->menu_mtime = menu_mtime;
    }
  }


  default_containers = ([ "h1" : default_h1_handler,
                          "a"  : default_link_handler ]);

  if (!silent) {
    write("\nStarting scanning and parsing...\n");
  }

  Stdio.write_file(tmp_file, Standards.JSON.encode(info));

  int starttime = time();

  recurse_dir(source_path, handle_path);

  if (!silent) {
    write("\nDone\n\n");
  }
  else {
    write("md2html: ");
  }

  write("Parsed %d file%s in %.2f seconds.\n",
        file_count, file_count == 1 ? "" : "s", time(starttime));

  if (!silent) {
    write("\n");
  }

	return 0;
}

void parse_config()
{
  if (config_path) {
    if (!Stdio.exist(config_path)) {
      werror("The path to the config file does not exist!\n");
      exit(1);
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

    if (t->keep_menu) {
      keep_menu = true;
    }

    if (has_index(t, "minify_html")) {
      minify_html = t->minify_html;
    }
  }
}

string minify_template(string template)
{
  if (minify_html) {
    Parser.HTML parser = Parser.HTML();

    parser->_set_data_callback(lambda (Parser.HTML pp, string data) {
      if (String.trim_all_whites(data) == "") {
        return "";
      }
    });

    template = parser->feed(template)->finish()->read();
  }

  return template;
}

string mktag(string name, mapping attr, void|string data)
{
  string out = "<" + name;
  if (attr && sizeof(attr)) {
    out += sprintf("%{ %s=\"%s\"%}", (array) attr);
  }

  out += ">";

  if (data) {
    out += data + "</" + name + ">";
  }

  return out;
}

string parse_template(string template)
{
  Parser.HTML p = Parser.HTML();

  p->add_tags(([
    "link" : lambda (Parser.HTML pp, mapping attr) {
      string fp = combine_path(template_path, attr->href);

      if (Stdio.exist(fp)) {
        info->mtimes[fp] = file_stat(fp)->mtime;
      }

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
    "img"  : lambda (Parser.HTML pp, mapping attr) {
      if (attr->src) {
        string fp = combine_path(template_path, attr->src);
        if (Stdio.exist(fp)) {
          info->mtimes[fp] = file_stat(fp)->mtime;

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

  p->add_containers(([
    "a"   : lambda (Parser.HTML pp, mapping attr, string data) {
      if (attr && attr->href) {
        if (sscanf (attr->href, "${%s-url}", string special_link) == 1) {
          special_links[special_link] =  ([
            "attr" : attr,
            "data" : data
          ]);

          return ({ "${special_link_" + special_link + "}" });
        }
      }

      data = pp->clone()->feed(data)->read();

      return ({ mktag(p->tag_name(), attr, data) });
    }
  ]));

  return p->feed(template)->finish()->read();
}

void parse_menu()
{
  if (menu_file) {
    Parser.HTML p = Parser.HTML();

    if (!silent) {
      write("\nParsing menu file...");
    }

    menu_file = combine_path(source_path, menu_file);

    int startpos, endpos;

    string menu_file_data = Stdio.read_file(menu_file);

    p->add_quote_tag("!--",
                     lambda (Parser.HTML pp, string data) {
                       string d = String.trim_all_whites(data);

                       if (d == "menu") {
                         startpos = pp->at()[1];
                         startpos += sizeof("<!--" + data + "-->");
                       }
                       else if (d == "endmenu") {
                         endpos = pp->at()[1] - 1;
                       }
                     },
                     "--");

    string menu_html = p->feed(menu_file_data)->finish()->read();
    menu_html = String.trim_all_whites(menu_html[startpos..endpos]);
    menu_html = Parser.Markdown.marked(menu_html, options);

    p->add_containers(([
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
          mapping(string:string) menu = ([
            "href"          : attr->href,
            "html_href"     : html_href,
            "basename"      : base_name,
            "basename_href" : base_name_href,
            "title"         : data ]);

          if (!menu_struct[pts[0]]) {
            menu_struct[pts[0]] = ([ "pos" : menu_pos++, "top" : menu ]);
          }

          if (!menu_struct[pts[0]]->pages) {
            menu_struct[pts[0]]->pages = ({});
          }
          else {
            menu_struct[pts[0]]->pages += ({ menu });
          }

          attr->href = replace(attr->href, ".md", ".html");

          return ({ sprintf("<a%{ %s=\"%s\"%}>%s</a>", (array)attr, data) });
        }
      }
    ]));

    p->feed(menu_html)->finish();

    menu_order = allocate(sizeof(indices(menu_struct)));

    foreach (indices(menu_struct), string k) {
      menu_order[menu_struct[k]->pos] = menu_struct[k];
    }

    if (!silent) {
      write("...done!\n");
    }
  }
}

mixed default_h1_handler(Parser.HTML pp, mapping attr, string data)
{
  if (!replacements->title) {
    replacements->title = data;
  }
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

string make_relative_path(string base, string href)
{
  array(string) b1 = dirname(base)/"/";
  array(string) h1 = dirname(href)/"/";

  if (h1[0] == "..") {
    return href;
  }

  // Would break on depths greater than one level
  if (b1[0] == h1[0]) {
    return basename(href);
  }

  string pf = "../" * sizeof(h1);

  return pf + href;
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

  string st_new_path = new_path;

  if (has_suffix(st_new_path, ".md")) {
    st_new_path = st_new_path - ".md" + ".html";
  }

  object st_org = file_stat(path);
  object st_new = file_stat(st_new_path);

  if (!regenerate_all &&
      (st_new && st_new->isreg && st_org->mtime < st_new->mtime))
  {
    if (!silent) {
      write("  * Not changed: %s\n", basename(new_path));
    }
    return;
  }

  string toppath = "../" * depth;
  if (toppath == "") toppath = "./";
  replacements->top_path = toppath + "index.html";
  replacements->top_class = sprintf("class='%s'",
                                    replace(relpath, "/", "-") - ".md");

  array(string) parts = name/".";
  array(string) rel_parts = relpath/"/";

  if (menu_file) {
    replacements->menu = render_menu(rel_parts[0], relpath, depth);
  }

  if (sizeof(parts) > 1 && lower_case(parts[-1]) == "md") {
    if (!silent) {
      write("  * Parsing: %s\n", name);
    }

    string html = Parser.Markdown.marked(Stdio.read_file(path), options);
    string nn = (parts[..<1] * ".") + ".html";

    replacements->data = fix_links(html);

    if (menu_file && path == menu_file && keep_menu != true) {
      Parser.HTML p = Parser.HTML();

      int sp, ep;
      p->add_quote_tag("!--",
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

      p->feed(replacements->data)->finish();
      replacements->data = replacements->data[..sp] + replacements->data[ep..];
    }

    replacements->special_link_prev = "";
    replacements->special_link_next = "";

    if (sizeof(special_links) && menu_file) {
      mapping section = menu_struct[rel_parts[0]];
      if (section) {
        int mypos = section->pos;
        mapping prev, next;

        int plen = sizeof(section->pages);

        if (section->top->href == relpath) {
          if (mypos == 0) {
            prev = ([
              "href" : "../index.html",
              "title" : "Start"
            ]);
          }
          else {
            if (mapping prev_section = menu_order[mypos-1]) {
              mapping tmp;
              if (sizeof(prev_section->pages)) {
                tmp = prev_section->pages[-1];
              }
              else {
                tmp = prev_section->top;
              }

              if (tmp) {
                prev = ([
                  "href" : tmp->html_href,
                  "title" : tmp->title
                ]);
              }
            }
          }

          if (plen > 0) {
            next = ([
              "href" : section->pages[0]->html_href,
              "title" : section->pages[0]->title
            ]);
          }
          else {
            if (has_index(menu_order, mypos+1)) {
              next = ([
                "href" : menu_order[mypos+1]->top->html_href,
                "title" : menu_order[mypos+1]->top->title
              ]);
            }
          }
        }
        else {
          if (plen > 0) {
            for (int i; i < plen; i++) {
              if (section->pages[i]->href == relpath) {
                mapping tmp_prev, tmp_next;

                if (i == 0) {
                  if (has_index(section->pages, i+1)) {
                    tmp_next = section->pages[i+1];
                  }
                  else {
                    if (has_index(menu_order, mypos+1)) {
                      tmp_next = menu_order[mypos+1]->top;
                    }
                  }
                  tmp_prev = section->top;
                }
                else if (i != plen-1) {
                  tmp_prev = section->pages[i-1];
                  tmp_next = section->pages[i+1];
                }
                else if (i == plen-1) {
                  tmp_prev = section->pages[i-1];
                  if (has_index(menu_order, mypos+1)) {
                    tmp_next = menu_order[mypos+1]->top;
                  }
                }

                if (tmp_prev) {
                  prev = ([
                    "href" : tmp_prev->html_href,
                    "title" : tmp_prev->title
                  ]);
                }
                if (tmp_next) {
                  next = ([
                    "href" : tmp_next->html_href,
                    "title" : tmp_next->title
                  ]);
                }
              }
            }
          }
        }

        if (prev) {
          special_links->prev->attr->href =
            make_relative_path(relpath, prev->href);

          replacements->special_link_prev =
            mktag("a", special_links->prev->attr, prev->title);
        }

        if (next) {
          special_links->next->attr->href =
            make_relative_path(relpath, next->href);

          replacements->special_link_next =
            mktag("a", special_links->next->attr, next->title);
        }
      }
    }

    mapping rr = ([]);

    foreach (indices(replacements), string key) {
      rr["${" + key + "}"] = replacements[key]||"";
    }

    html = replace(template, rr);
    new_path = replace(new_path, name, nn);
    Stdio.write_file(new_path, html);

    file_count++;
  }
  else {
    if (!source_is_dest) {
      Stdio.cp(path, new_path);
    }
  }
}

string render_menu(string index, string current, void|int depth)
{
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
  if (!silent) {
    write("\nScanning: %s\n", path);
  }

  foreach (get_dir(path), string p) {
    string fp = combine_path(path, p);

    if (SKIP(fp)) {
      if (!silent) {
        write("  # Skipping %s: %s\n", Stdio.is_dir(fp) ? "dir" : "file", fp);
      }
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
