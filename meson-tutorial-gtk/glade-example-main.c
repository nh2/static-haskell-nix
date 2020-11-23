#include <gtk/gtk.h>

// Roughly following https://prognotes.net/2016/03/gtk-3-c-code-hello-world-tutorial-using-glade-3/

GtkWidget *g_label_hello;
GtkWidget *g_button_count;

void on_button_hello_clicked()
{
  static unsigned int count = 0;
  char str_count[30] = {0};

  count++;
  snprintf(str_count, 30, "%d", count);
  gtk_label_set_text(GTK_LABEL(g_label_hello), str_count);
}

// called when window is closed
void on_window_main_destroy()
{
  gtk_main_quit();
}

int main(int argc, char **argv)
{
  GtkBuilder *builder;
  GtkWidget *window;

  gtk_init(&argc, &argv);

  builder = gtk_builder_new();
  GError *error = NULL;
  if (0 == gtk_builder_add_from_file(builder, "glade-example.glade", &error))
  {
    g_printerr("Error loading file: %s\n", error->message);
    g_clear_error(&error);
    return 1;
  }

  window = GTK_WIDGET(gtk_builder_get_object(builder, "window_main"));
  gtk_builder_connect_signals(builder, NULL);

  // get pointers to the two labels
  g_label_hello = GTK_WIDGET(gtk_builder_get_object(builder, "label_hello"));

  g_object_unref(builder);

  gtk_widget_show(window);
  gtk_main();

  return 0;
}
