project('tutorial', 'c')
# project('tutorial', 'c', default_options: ['c_link_args=-static'])

# executable('demo', 'main.c')
executable('demo', 'main.c', link_args: '-static', install: true)

gtkdep = dependency('gtk+-3.0', static: true)

executable('demo-gtk', 'gtkmain.c', dependencies: gtkdep, install: true, link_args: '-static')
