mame -inipath /opt/retropie/emulators/mame/ini \
     -cfg_directory /opt/retropie/emulators/mame/cfg_sa \
     -numscreens 2 \
     -resolution 320x240 \
     -effect scanlines \
     -video opengl \
     -prescale 1 \
     -waitvsync \
     -nothrottle \
     -nosleep \
     -noautoframeskip \
     -nofilter \
     -gl_glsl \
     -gl_glsl_filter 0 \
     punchout
