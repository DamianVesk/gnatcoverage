#include "sensors.h"
#include "slists_fault.h"

#include <assert.h>

int
main (void)
{
  struct sensor s1, s2;
  struct sensor_list l;
  struct sensor_list skipped, fault, ok;

  sensor_init (1, 1, &s1);
  s1.value = 1;
  s1.active = true;

  sensor_init (1, 1, &s2);
  s2.value = 2;
  s2.active = false;

  slist_init (&l);
  slist_prepend (&s1, &l);
  slist_prepend (&s2, &l);

  slist_init (&skipped);
  slist_init (&fault);
  slist_init (&ok);

  slist_control (&l, true, &skipped, &fault, &ok);

  assert (skipped.len == 1);
  assert (fault.len == 0);
  assert (ok.len == 1);
  return 0;
}

//# slists_fault.c
//  /AF_init/   l+ ## 0
//  /AF_while/  l+ ## 0
//  /AF_evA/    l+ ## 0
//  /AF_skip/   l+ ## 0
//  /AF_evLB/   l+ ## 0
//  /AF_evHB/   l+ ## 0
//  /AF_fault/  l- ## s-
//  /AF_ok/     l+ ## 0
//  /AF_next/   l+ ## 0