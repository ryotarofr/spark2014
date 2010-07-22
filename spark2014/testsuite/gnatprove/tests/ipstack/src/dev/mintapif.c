/*-----------------------------------------------------------------------------------*/
/*
 * Copyright (c) 2001-2003 Swedish Institute of Computer Science.
 * Copyright (C) 2010, AdaCore
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification,
 * are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice,
 *    this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 * 3. The name of the author may not be used to endorse or promote products
 *    derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR IMPLIED
 * WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT
 * SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT
 * OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
 * IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY
 * OF SUCH DAMAGE.
 *
 * This file is part of the lwIP TCP/IP stack.
 *
 * Author: Adam Dunkels <adam@sics.se>
 *
 */

#include <fcntl.h>
#include <stdlib.h>
#include <stdio.h>
#include <unistd.h>
#include <string.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/time.h>
#include <sys/uio.h>
#include <sys/socket.h>

#if defined(linux)
#include <sys/ioctl.h>
#include <linux/if.h>
#include <linux/if_tun.h>
#define DEVTAP "/dev/net/tun"
#define IFCONFIG_ARGS "tap0 inet %d.%d.%d.%d"

#elif defined(openbsd)
#define DEVTAP "/dev/tun0"
#define IFCONFIG_ARGS "tun0 inet %d.%d.%d.%d link0"

#else /* freebsd, cygwin? */
#define DEVTAP "/dev/tap0"
#define IFCONFIG_ARGS "tap0 inet %d.%d.%d.%d"
#endif

#include "aip.h"
#include "mintapif.h"

/* Define those to better describe your network interface. */
#define IFNAME0 'e'
#define IFNAME1 't'

struct mintapif {
  Ethernet_Address *ethaddr;
  /* Add whatever per-interface state that is needed here. */
  unsigned long lasttime;
  int fd;
};

/* Forward declarations. */
static void  mintapif_input(Netif_Id nid);

/*-----------------------------------------------------------------------------------*/

/*
 * The following are hardcoded and should instead be made configurable:
 *   MAC address
 *   host IP address
*/

#define HOST_IP_ADDRESS_1 192
#define HOST_IP_ADDRESS_2 168
#define HOST_IP_ADDRESS_3 100
#define HOST_IP_ADDRESS_4 1

static void
low_level_init(struct netif *netif)
{
  struct mintapif *mintapif;
  char buf[1024];

  mintapif = netif->Dev;

  /* Obtain MAC address from network interface. */
  (*mintapif->ethaddr)[0] = 1;
  (*mintapif->ethaddr)[1] = 2;
  (*mintapif->ethaddr)[2] = 3;
  (*mintapif->ethaddr)[3] = 4;
  (*mintapif->ethaddr)[4] = 5;
  (*mintapif->ethaddr)[5] = 6;

  /* Do whatever else is needed to initialize interface. */

  mintapif->fd = open(DEVTAP, O_RDWR);
  if (mintapif->fd == -1) {
    perror("tapif: tapif_init: open");
    exit(1);
  }

#ifdef linux
  {
    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    ifr.ifr_flags = IFF_TAP|IFF_NO_PI;
    if (ioctl(mintapif->fd, TUNSETIFF, (void *) &ifr) < 0) {
      perror(buf);
      exit(1);
    }
  }
#endif /* Linux */

  snprintf(buf, sizeof(buf), "/sbin/ifconfig " IFCONFIG_ARGS,
           HOST_IP_ADDRESS_1,
           HOST_IP_ADDRESS_2,
           HOST_IP_ADDRESS_3,
           HOST_IP_ADDRESS_4);

  system(buf);

  mintapif->lasttime = 0;

}
/*-----------------------------------------------------------------------------------*/
/*
 * low_level_output():
 *
 * Should do the actual transmission of the packet. The packet is
 * contained in the pbuf that is passed to the function. This pbuf
 * might be chained.
 *
 */
/*-----------------------------------------------------------------------------------*/

static err_t
low_level_output(Netif_Id Nid, Buffer_Id p)
{
  struct netif *netif = AIP_get_netif (Nid);
  struct mintapif *mintapif;
  Buffer_Id q;
  char buf[1514];
  char *bufptr;
  int written;

  mintapif = netif->Dev;

  /* initiate transfer(); */

  bufptr = &buf[0];

  for(q = p; q != NOBUF; q = AIP_buffer_next (q)) {
    U16_T len = AIP_buffer_len (q);
    /* Send the data from the pbuf to the interface, one pbuf at a
       time. The size of the data in each pbuf is kept in the ->len
       variable. */
    /* send data from(q->payload, q->len); */
    memcpy(bufptr, AIP_buffer_payload (q), len);
    bufptr += len;
    /* Check that bufptr does not overflow??? */
  }

  /* signal that packet should be sent(); */
  written = write(mintapif->fd, buf, AIP_buffer_tlen (p));
  if (written == -1) {
    perror("tapif: write");
    /* return ERR_xxx; ??? */
  }
  return NOERR;
}
/*-----------------------------------------------------------------------------------*/
/*
 * low_level_input():
 *
 * Should allocate a pbuf and transfer the bytes of the incoming
 * packet from the interface into the pbuf.
 *
 */
/*-----------------------------------------------------------------------------------*/
static Buffer_Id
low_level_input(struct netif *netif)
{
  Buffer_Id p, q;
  U16_T len;
  char buf[1514];
  char *bufptr;
  struct mintapif *mintapif;

  mintapif = netif->Dev;

  /* Obtain the size of the packet and put it into the "len"
     variable. */
  len = read(mintapif->fd, buf, sizeof(buf));

  /*  if (((double)rand()/(double)RAND_MAX) < 0.1) {
    printf("drop\n");
    return NULL;
    }*/

  /* We allocate a pbuf chain of pbufs from the pool. */
  AIP_buffer_alloc (0, len, LINK_BUF, &p);
  if (p != NOBUF) {
    /* We iterate over the pbuf chain until we have read the entire
       packet into the pbuf. */
    bufptr = &buf[0];
    for(q = p; q != NOBUF; q = AIP_buffer_next (q)) {
      U16_T len = AIP_buffer_len (q);
      /* Read enough bytes to fill this pbuf in the chain. The
         available data in the pbuf is given by the q->len
         variable. */
      /* read data into(q->payload, q->len); */
      memcpy(AIP_buffer_payload (q), bufptr, len);
      bufptr += len;
    }
    /* acknowledge that packet has been read(); */
  } else {
    /* drop packet(); */
    printf("Could not allocate pbufs\n");
  }

  return p;
}
/*-----------------------------------------------------------------------------------*/
/*
 * mintapif_input():
 *
 * This function should be called when a packet is ready to be read
 * from the interface. It uses the function low_level_input() that
 * should handle the actual reception of bytes from the network
 * interface.
 *
 */
/*-----------------------------------------------------------------------------------*/
static void
mintapif_input (Netif_Id nid)
{
  Err_T err;
  struct netif *netif = AIP_get_netif (nid);
  struct mintapif *mintapif;
  Ether_Header *ethhdr;
  Buffer_Id p;

  mintapif = netif->Dev;

  p = low_level_input (netif);

  if (p != NOBUF) {

    ethhdr = (Ether_Header *) AIP_buffer_payload (p);

    switch (AIP_etherh_frame_type (*ethhdr)) {
    case Ether_Type_IP:
#if 0
/* CSi disabled ARP table update on ingress IP packets.
   This seems to work but needs thorough testing. */
      AIP_arpip_input(netif, p);
#endif

      /* Suspicious hard-coded constant -14??? */
      AIP_buffer_header (p, -14, &err);

      ((Input_CB_T)netif->Input_CB) (nid, p);
      break;
    case Ether_Type_ARP:
      AIP_arp_input (nid, mintapif->ethaddr, p);
      break;

    default:
      /* LWIP_ASSERT("p != NOBUF", p != NOBUF); */
      AIP_buffer_blind_free (p);
      break;
    }
  }
}

/*-----------------------------------------------------------------------------------*/
/*
 * mintapif_init():
 *
 * Should be called at the beginning of the program to set up the
 * network interface. It calls the function low_level_init() to do the
 * actual setup of the hardware.
 *
 */
/*-----------------------------------------------------------------------------------*/

static int initialized = 0;
static struct mintapif mintapif_dev;

void
mintapif_init (Err_T *Err, Netif_Id *Nid)
{
  struct netif *netif;
  struct mintapif *mintapif;

  if (initialized) {
    *Err = ERR_MEM;
    return;
  }

  AIP_allocate_netif (Nid);
  if (*Nid == IF_NOID) {
    *Err = ERR_MEM;
    return;
  }

  netif = AIP_get_netif (*Nid);

/* Support multiple mintapif instances???
  mintapif = mem_malloc(sizeof(struct mintapif));
  if (mintapif == NULL)
  {
    return ERR_MEM;
  }
*/
  mintapif = &mintapif_dev;
  netif->Dev = mintapif;
#if LWIP_SNMP
  /* ifType is other(1), there doesn't seem
     to be a proper type for the tunnel if */
  netif->link_type = 1;
  /* @todo get this from struct tunif? */
  netif->link_speed = 0;
  netif->ts = 0;
  netif->ifinoctets = 0;
  netif->ifinucastpkts = 0;
  netif->ifinnucastpkts = 0;
  netif->ifindiscards = 0;
  netif->ifoutoctets = 0;
  netif->ifoutucastpkts = 0;
  netif->ifoutnucastpkts = 0;
  netif->ifoutdiscards = 0;
#endif

  netif->Name[0] = IFNAME0;
  netif->Name[1] = IFNAME1;
  netif->Input_CB       = (CBK_Id) AIP_ip_input;
  netif->Output_CB      = (CBK_Id) AIP_arp_output;
  netif->Link_Output_CB = (CBK_Id) low_level_output;
  netif->MTU = 1500;

  netif->LL_Address_Length = 6;
  mintapif->ethaddr = (Ethernet_Address*)&(netif->LL_Address[0]);

  low_level_init(netif);

  netif->State = Up;
  *Err = NOERR;
}
/*-----------------------------------------------------------------------------------*/
enum mintapif_signal
mintapif_wait(Netif_Id nid, U16_T time)
{
  struct netif *netif = AIP_get_netif (nid);
  fd_set fdset;
  struct timeval tv, now;
  struct timezone tz;
  int ret;
  struct mintapif *mintapif;

  mintapif = netif->Dev;

  while (1) {

    if (mintapif->lasttime >= (U32_T) time * 1000) {
      mintapif->lasttime = 0;
      return MINTAPIF_TIMEOUT;
    }

    tv.tv_sec = 0;
    tv.tv_usec = (U32_T) time * 1000 - mintapif->lasttime;


    FD_ZERO(&fdset);
    FD_SET(mintapif->fd, &fdset);

    gettimeofday(&now, &tz);
    ret = select(mintapif->fd + 1, &fdset, NULL, NULL, &tv);
    if (ret == 0) {
      mintapif->lasttime = 0;
      return MINTAPIF_TIMEOUT;
    }
    gettimeofday(&tv, &tz);
    mintapif->lasttime += (tv.tv_sec - now.tv_sec) * 1000000 + (tv.tv_usec - now.tv_usec);

    mintapif_input (nid);
  }

  return MINTAPIF_PACKET;
}

static int
mintapif_select(Netif_Id nid)
{
  struct netif *netif = AIP_get_netif (nid);
  fd_set fdset;
  int ret;
  struct timeval tv;
  struct mintapif *mintapif;

  mintapif = netif->Dev;

  tv.tv_sec = 0;
  tv.tv_usec = 0; /* usec_to; */

  FD_ZERO(&fdset);
  FD_SET(mintapif->fd, &fdset);

  ret = select(mintapif->fd + 1, &fdset, NULL, NULL, &tv);
  if (ret > 0) {
    mintapif_input (nid);
  }
  return ret;
}

extern int
mintapif_isr (Netif_Id nid) {
  sigset_t oldmask, empty;

  /* start of critical section,
     poll netif, pass packet to lwIP */
  if (mintapif_select(nid) > 0)
  {
    /* work, immediatly end critical section
       hoping lwIP ended quickly ... */
    sigprocmask(SIG_SETMASK, &oldmask, NULL);
  }
  else
  {
    /* no work, wait a little (10 msec) for SIGALRM */
      sigemptyset(&empty);
      sigsuspend(&empty);
    /* ... end critical section */
      sigprocmask(SIG_SETMASK, &oldmask, NULL);
  }
}
