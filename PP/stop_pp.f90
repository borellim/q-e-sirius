!
! Copyright (C) 2001 PWSCF group
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!
!--------------------------------------------------------------------
subroutine stop_pp
  !--------------------------------------------------------------------
  !
  ! Synchronize processes before stopping.
  !
  use mp, only: mp_end, mp_barrier
  USE parallel_include
#ifdef __PARA

  integer :: info
  
  call mp_barrier()

  ! call mpi_finalize (info)
#endif
 
  call mp_end()

#ifdef __T3E
  !
  ! set streambuffers off
  !

  call set_d_stream (0)
#endif

  stop
end subroutine stop_pp
