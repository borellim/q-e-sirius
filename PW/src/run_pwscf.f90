!
! Copyright (C) 2013-2017 Quantum ESPRESSO group
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!
!----------------------------------------------------------------------------
SUBROUTINE run_pwscf ( exit_status ) 
  !----------------------------------------------------------------------------
  !
  !! author: Paolo Giannozzi
  !! license: GNU 
  !! summary: Run an instance of the Plane Wave Self-Consistent Field code
  !!
  !! Run an instance of the Plane Wave Self-Consistent Field code 
  !! MPI initialization and input data reading is performed in the 
  !! calling code - returns in exit_status the exit code for pw.x, 
  !! returned in the shell. Values are:
  !! * 0: completed successfully
  !! * 1: an error has occurred (value returned by the errore() routine)
  !! * 2-127: convergence error
  !!   * 2: scf convergence error
  !!   * 3: ion convergence error
  !! * 128-255: code exited due to specific trigger
  !!   * 255: exit due to user request, or signal trapped,
  !!          or time > max_seconds
  !!     (note: in the future, check_stop_now could also return a value
  !!     to specify the reason of exiting, and the value could be used
  !!     to return a different value for different reasons)
  !! @Note
  !! 10/01/17 Samuel Ponce: Add Ford documentation
  !! @endnote
  !!
  !
  USE io_global,        ONLY : stdout, ionode, ionode_id
  USE parameters,       ONLY : ntypx, npk, lmaxx
  USE cell_base,        ONLY : fix_volume, fix_area
  USE control_flags,    ONLY : conv_elec, gamma_only, ethr, lscf, twfcollect
  USE control_flags,    ONLY : conv_ions, istep, nstep, restart, lmd, lbfgs
  USE command_line_options, ONLY : command_line
  USE force_mod,        ONLY : lforce, lstres, sigma, force
  USE check_stop,       ONLY : check_stop_init, check_stop_now
  USE mp_images,        ONLY : intra_image_comm
  USE extrapolation,    ONLY : update_file, update_pot
  USE scf,              ONLY : rho
  USE lsda_mod,         ONLY : nspin
  USE fft_base,         ONLY : dfftp
  USE qmmm,             ONLY : qmmm_initialization, qmmm_shutdown, &
                               qmmm_update_positions, qmmm_update_forces
  USE qexsd_module,     ONLY:   qexsd_set_status
  use mod_sirius
  USE fft_base,               ONLY : dfftp, dffts
  USE cell_base,              ONLY : at, bg
  USE gvect,                  ONLY : gcutm
  USE gvecs,                  ONLY : gcutms
  USE mp_bands,               ONLY : intra_bgrp_comm, nyfft
  USE fft_types,              ONLY : fft_type_allocate  
  !
  IMPLICIT NONE
  INTEGER, INTENT(OUT) :: exit_status
  !! Gives the exit status at the end
  LOGICAL, external :: matches
  !! checks if first string is contained in the second
  INTEGER :: idone 
  ! counter of electronic + ionic steps done in this run
  LOGICAL(C_BOOL) :: flg
  !
  if (use_sirius) then
     ! initialize platform-specific stuff (libraries, environment, etc.)
     flg = .false.
     CALL sirius_initialize(call_mpi_init=flg)
  endif
  exit_status = 0
  IF ( ionode ) WRITE( unit = stdout, FMT = 9010 ) ntypx, npk, lmaxx
  !
  IF (ionode) CALL plugin_arguments()
  CALL plugin_arguments_bcast( ionode_id, intra_image_comm )
  !
  ! ... needs to come before iosys() so some input flags can be
  !     overridden without needing to write PWscf specific code.
  ! 
  CALL qmmm_initialization()
  !
  ! ... convert to internal variables
  !
  CALL iosys()
  !
  ! ... If executable names is "dist.x", compute atomic distances, angles,
  ! ... nearest neighbors, write them to file "dist.out", exit
  !
  IF ( matches('dist.x',command_line) ) THEN
     IF (ionode) CALL run_dist ( exit_status )
     RETURN
  END IF
  !
  IF ( gamma_only ) WRITE( UNIT = stdout, &
     & FMT = '(/,5X,"gamma-point specific algorithms are used")' )
  !
  ! call to void routine for user defined / plugin patches initializations
  !
  CALL plugin_initialization()
  !
  CALL check_stop_init()
  !
  CALL setup ()
  !
  CALL qmmm_update_positions()
  !
  if (.not.recompute_gvec) then
    IF ( check_stop_now() ) THEN
       CALL pre_init()
       CALL data_structure( gamma_only )
       CALL summary()
       CALL memory_report()
       CALL qexsd_set_status(255)
       CALL punch( 'config' )
       exit_status = 255
       RETURN
    ENDIF
    CALL init_run()
    !
    ! ... dry run: code will stop here if called with exit file present
    ! ... useful for a quick and automated way to check input data
    !
    IF ( check_stop_now() ) THEN
       CALL qexsd_set_status(255)
       CALL punch( 'config' )
       exit_status = 255
       RETURN
    ENDIF
  endif
  !
  main_loop: DO idone = 1, nstep
     if (recompute_gvec) then
        if (idone.gt.1) then
          CALL reset_starting_magnetization ( )
        endif
        CALL clean_pw( .FALSE. )
        CALL close_files(.TRUE.)
        dfftp%nr1=0; dfftp%nr2=0; dfftp%nr3=0
        CALL fft_type_allocate (dfftp, at, bg, gcutm, intra_bgrp_comm, nyfft=nyfft)
        dffts%nr1=0; dffts%nr2=0; dffts%nr3=0
        CALL fft_type_allocate (dffts, at, bg, gcutms,intra_bgrp_comm, nyfft=nyfft)
        CALL init_run()
        !
        ! ... dry run: code will stop here if called with exit file present
        ! ... useful for a quick and automated way to check input data
        !
        IF ( check_stop_now() ) THEN
           CALL qexsd_set_status(255)
           CALL punch( 'config' )
           exit_status = 255
           RETURN
        ENDIF
     endif
     !
     ! ... electronic self-consistency or band structure calculation
     !
     IF ( .NOT. lscf) THEN
        CALL non_scf ()
     ELSE
        CALL electrons()
     END IF
     !
     ! ... code stopped by user or not converged
     !
     IF ( check_stop_now() .OR. .NOT. conv_elec ) THEN
        IF ( check_stop_now() ) exit_status = 255
        IF ( .NOT. conv_elec )  exit_status =  2
        CALL qexsd_set_status(exit_status)
        ! workaround for the case of a single k-point
        twfcollect = .FALSE.
        CALL punch( 'config' )
        RETURN
     ENDIF
     !
     ! ... ionic section starts here
     !
     CALL start_clock( 'ions' ); !write(*,*)' start ions' ; FLUSH(6)
     conv_ions = .TRUE.
     !
     ! ... recover from a previous run, if appropriate
     !
     !IF ( restart .AND. lscf ) CALL restart_in_ions()
     !
     ! ... file in CASINO format written here if required
     !
     IF ( lmd ) THEN
        CALL pw2casino( istep )
     ELSE
        CALL pw2casino( 0 )
     END IF
     !
     ! ... force calculation
     !
     IF ( lforce ) CALL forces()
     !
     ! ... stress calculation
     !
     IF ( lstres ) CALL stress ( sigma )
     !
     ! ... send out forces to MM code in QM/MM run
     !
     IF ( lmd .OR. lbfgs ) THEN
        !
        if (fix_volume) CALL impose_deviatoric_stress(sigma)
        if (fix_area)  CALL  impose_deviatoric_stress_2d(sigma)
        !
        ! ... save data needed for potential and wavefunction extrapolation
        !
        CALL update_file ( )
        !
        ! ... ionic step (for molecular dynamics or optimization)
        !
        CALL move_ions ( idone )
        !
        ! ... then we save restart information for the new configuration
        !
        IF ( idone <= nstep .AND. .NOT. conv_ions ) THEN 
            CALL qexsd_set_status(255)
            CALL punch( 'config' )
        END IF
        !
     END IF
     !
     CALL stop_clock( 'ions' ); !write(*,*)' stop ions' ; FLUSH(6)
     !
     CALL qmmm_update_forces( force, rho%of_r, nspin, dfftp)
     !
     ! ... exit condition (ionic convergence) is checked here
     !
     IF ( lmd .OR. lbfgs ) CALL add_qexsd_step(idone)
     IF ( conv_ions ) EXIT main_loop
     !
     ! ... receive new positions from MM code in QM/MM run
     !
     CALL qmmm_update_positions()
     !
     ! ... terms of the hamiltonian depending upon nuclear positions
     ! ... are reinitialized here
     !
     IF ( lmd .OR. lbfgs ) THEN
        !
        ! ... update the wavefunctions, charge density, potential
        ! ... update_pot initializes structure factor array as well
        !
        if (.not.(use_sirius.and.recompute_gvec)) then
          CALL update_pot()
        endif
        !
        ! ... re-initialize atomic position-dependent quantities
        !
        CALL hinit1()
        !
     END IF
     ! ... Reset convergence threshold of iterative diagonalization for
     ! ... the first scf iteration of each ionic step (after the first)
     !
     ethr = 1.0D-6
     !
     if (use_sirius) then
       call clear_sirius
     endif
  END DO main_loop
  !
  ! ... save final data file
  !
  CALL qexsd_set_status(exit_status)
  if (use_sirius.and.use_sirius_ks_solver) then
    call get_wave_functions_from_sirius
  endif
  CALL punch('all')
  !
  CALL qmmm_shutdown()
  !
  IF ( .NOT. conv_ions )  exit_status =  3
  if (use_sirius) then
     call sirius_print_timers
     call sirius_clear
     call sirius_finalize(call_mpi_fin=flg)
  endif
  RETURN
  !
9010 FORMAT( /,5X,'Current dimensions of program PWSCF are:', &
           & /,5X,'Max number of different atomic species (ntypx) = ',I2,&
           & /,5X,'Max number of k-points (npk) = ',I6,&
           & /,5X,'Max angular momentum in pseudopotentials (lmaxx) = ',i2)
  !
END SUBROUTINE run_pwscf
