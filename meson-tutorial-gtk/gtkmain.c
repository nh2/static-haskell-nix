#include <gtk/gtk.h>

void button_event(GtkWidget *widget, gpointer *data) {
  g_print("Button clicked\n");
  gtk_button_set_label(GTK_BUTTON(widget), "It worked!");
}

int main(int argc, char **argv) {
  GtkWidget *win;
  gtk_init(&argc, &argv);
  win = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_window_set_title(GTK_WINDOW(win), "Hello there");
  g_signal_connect(win, "destroy", G_CALLBACK(gtk_main_quit), NULL);

  GtkWidget *button = gtk_button_new_with_mnemonic("_Click me!");
  gtk_widget_show(button);
  g_signal_connect(button, "pressed", G_CALLBACK(button_event), NULL);
  gtk_container_add(GTK_CONTAINER(win), button);

  gtk_widget_show(win);
  gtk_main();
}
